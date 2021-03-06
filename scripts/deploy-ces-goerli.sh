#!/bin/bash
set -eo pipefail

source "${BASH_SOURCE%/*}/_common.sh"
# shellcheck disable=SC1091
source "${BASH_SOURCE%/*}/build-env-addresses.sh" ces-goerli >&2

[[ "$ETH_RPC_URL" && "$(seth chain)" == "goerli" ]] || die "Please set a goerli ETH_RPC_URL"

export ETH_GAS=6000000

# TODO: confirm with DAO at the time of mainnet deployment if OFH will indeed be 007
[[ -z "$NAME" ]] && NAME="RWA-009"
[[ -z "$SYMBOL" ]] && SYMBOL="RWA009"
#
# WARNING (2021-09-08): The system cannot currently accomodate any LETTER beyond
# "A".  To add more letters, we will need to update the PIP naming convention
# naming convention.  So, before we can have new letters we must:
# 1. Change the existing PIP naming convention
# 2. Change all the places that depend on that convention (this script included)
# 3. Make sure all integrations are ready to accomodate that new PIP name.
# ! TODO: check with team/PE if this is still the case
#
[[ -z "$LETTER" ]] && LETTER="A"

# [[ -z "$MIP21_LIQUIDATION_ORACLE" ]] && MIP21_LIQUIDATION_ORACLE="0xDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF"
# TODO: confirm liquidations handling - no liquidations for the time being

ILK="${SYMBOL}-${LETTER}"
debug "ILK: ${ILK}"
ILK_ENCODED="$(cast --from-ascii "$ILK" | cast --to-bytes32)"

# build it
make build

FORGE_DEPLOY="${BASH_SOURCE%/*}/forge-deploy.sh"
CAST_SEND="${BASH_SOURCE%/*}/cast-send.sh"

# tokenize it
[[ -z "$RWA_TOKEN" ]] && {
    debug 'WARNING: `$RWA_TOKEN` not set. Deploying it...'
    TX=$($CAST_SEND "${RWA_TOKEN_FAB}" 'createRwaToken(string,string,address)' "$NAME" "$SYMBOL" "$MCD_PAUSE_PROXY")
    debug "TX: $TX"

    RECEIPT="$(cast receipt --json $TX)"
    TX_STATUS="$(jq -r '.status' <<<"$RECEIPT")"
    [[ "$TX_STATUS" != "0x1" ]] && die "Failed to create ${SYMBOL} token in tx ${TX}."

    RWA_TOKEN="$(jq -r ".logs[0].address" <<<"$RECEIPT")"
    debug "${SYMBOL}: ${RWA_TOKEN}"
} || {
    debug "${SYMBOL}: ${RWA_TOKEN}"
}

# route it
[[ -z "$DESTINATION_ADDRESS" ]] && die "DESTINATION_ADDRESS is not set"
debug "${SYMBOL}_${LETTER}_OUTPUT_CONDUIT: ${DESTINATION_ADDRESS}"

# join it
[[ -z "$RWA_JOIN" ]] && {
    RWA_JOIN=$($FORGE_DEPLOY --verify AuthGemJoin --constructor-args "$MCD_VAT" "$ILK_ENCODED" "$RWA_TOKEN")
    debug "MCD_JOIN_${SYMBOL}_${LETTER}: ${RWA_JOIN}"
    $CAST_SEND "$RWA_JOIN" 'rely(address)' "$MCD_PAUSE_PROXY" &&
        $CAST_SEND "$RWA_JOIN" 'deny(address)' "$ETH_FROM"
} || {
    debug "MCD_JOIN_${SYMBOL}_${LETTER}: ${RWA_JOIN}"
}

# urn it
[[ -z "$RWA_URN" ]] && {
    RWA_URN=$($FORGE_DEPLOY --verify RwaUrn2 --constructor-args "$MCD_VAT" "$MCD_JUG" "$RWA_JOIN" "$MCD_JOIN_DAI" "$DESTINATION_ADDRESS")
    debug "${SYMBOL}_${LETTER}_URN: ${RWA_URN}"
    $CAST_SEND "$RWA_URN" 'rely(address)' "$MCD_PAUSE_PROXY" &&
        $CAST_SEND "$RWA_URN" 'deny(address)' "$ETH_FROM"
} || {
    debug "${SYMBOL}_${LETTER}_URN: ${RWA_URN}"
}

# jar it
[[ -z "$RWA_JAR" ]] && {
    RWA_JAR=$($FORGE_DEPLOY --verify RwaJar --constructor-args "$CHANGELOG")
}
debug "${SYMBOL}_${LETTER}_JAR: ${RWA_JAR}"

# price it
[[ -z "$MIP21_LIQUIDATION_ORACLE" ]] && {
    MIP21_LIQUIDATION_ORACLE=$($FORGE_DEPLOY --verify RwaLiquidationOracle --constructor-args "$MCD_VAT" "$MCD_VOW")
    debug "MIP21_LIQUIDATION_ORACLE: ${MIP21_LIQUIDATION_ORACLE}"

    $CAST_SEND "$MIP21_LIQUIDATION_ORACLE" 'rely(address)' "$MCD_PAUSE_PROXY" &&
        $CAST_SEND "$MIP21_LIQUIDATION_ORACLE" 'deny(address)' "$ETH_FROM"
} || {
    debug "MIP21_LIQUIDATION_ORACLE: ${MIP21_LIQUIDATION_ORACLE}"
}

# print it
cat <<JSON
{
    "MIP21_LIQUIDATION_ORACLE": "${MIP21_LIQUIDATION_ORACLE}",
    "RWA_TOKEN_FAB": "${RWA_TOKEN_FAB}",
    "SYMBOL": "${SYMBOL}",
    "NAME": "${NAME}",
    "ILK": "${ILK}",
    "${SYMBOL}": "${RWA_TOKEN}",
    "MCD_JOIN_${SYMBOL}_${LETTER}": "${RWA_JOIN}",
    "${SYMBOL}_${LETTER}_URN": "${RWA_URN}",
    "${SYMBOL}_${LETTER}_JAR": "${RWA_JAR}",
    "${SYMBOL}_${LETTER}_OUTPUT_CONDUIT": "${DESTINATION_ADDRESS}"
}
JSON
