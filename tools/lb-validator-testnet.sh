#!/usr/bin/env bash
# Deploys a copy of Limit Break's creator-token transfer validator (v3.0.0) on Robinhood Chain
# testnet (46630), for the mint rehearsal only. Mainnet uses only Limit Break's own deployment,
# and this script refuses any chain but 46630.
#
# The copy cannot land at Limit Break's canonical address (0x721C0078c2328597Ca70F5451ffF5A7B38D4E947).
# That address comes from their CREATE2 salt with their owner address in the constructor, and the
# validator's constructor reads a configuration contract that only their owner can initialise. A
# copy owned by anyone else stops at that step. So the copy here is Limit Break's published code at
# the v3.0.0 tag, with the throwaway deployer as its owner:
#   EOA registry        Limit Break's own, at its canonical 0xE0A0004Dfa318fc38298aE81a666710eaDCEba5C
#                       (no owner, so anyone can deploy it there; reused if already present)
#   configuration       a copy owned by the deployer, initialised with the pause-check value
#   transfer validator  a copy owned by the deployer, at an address this script prints
# Both copies go through the standard CREATE2 proxy with a zero salt, so the addresses depend only
# on the deployer and are the same every time the script runs with the same wallet.
#
# The creation bytecode is not built here. Building it locally gives a different result on
# different machines: the compiler writes a hash of its metadata (which includes the build's
# remappings, with absolute paths under Foundry 1.8) into the tail of the bytecode, so the init
# code and with it every CREATE2 address change with the Foundry version and the clone's path.
# Instead tools/lib/limit-break/ holds the exact creation code of the three contracts (see its
# README), and before anything is sent this script proves each file is the published code: with
# Limit Break's own salts and owner it must produce their three canonical addresses.
#
# Reads DEPLOYER_PRIVATE_KEY and RPC_URL from contracts/.env (the throwaway testnet wallet).
#
#   bash tools/lb-validator-testnet.sh                 check, then deploy what is missing
#   bash tools/lb-validator-testnet.sh --check         check and print the addresses, send nothing
#   bash tools/lb-validator-testnet.sh --own-registry  deploy a registry copy at its own address
#                                                      (zero salt) instead of the canonical one,
#                                                      and point the validator copy at it
set -euo pipefail

CHECK_ONLY=0
OWN_REGISTRY=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    --own-registry) OWN_REGISTRY=1 ;;
    *) echo "STOP: unknown option $arg (use --check and/or --own-registry)" >&2; exit 1 ;;
  esac
done

die() { echo "STOP: $*" >&2; exit 1; }
command -v cast >/dev/null 2>&1 || die "cast is missing: install Foundry first (foundryup), then reopen the terminal"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$HERE/tools/lib/limit-break"
[ -f "$HERE/.env" ] || die "contracts/.env is missing: copy .env.example to .env and fill it in (setup guide, part C)"
set -a
# shellcheck disable=SC1091
. "$HERE/.env"
set +a
[ -n "${RPC_URL:-}" ] || die "RPC_URL is empty in contracts/.env"
[ "$CHECK_ONLY" = 1 ] || [ -n "${DEPLOYER_PRIVATE_KEY:-}" ] || die "DEPLOYER_PRIVATE_KEY is empty in contracts/.env"

CHAIN="$(cast chain-id --rpc-url "$RPC_URL")"
[ "$CHAIN" = "46630" ] || die "this is chain $CHAIN, not Robinhood Chain testnet 46630. The copy is for the testnet rehearsal only."

# Limit Break's published values at v3.0.0 (.env.common in their repository): the proxy, their
# owner, their salts and the addresses those give on every chain.
PROXY="0x4e59b44847b379578588920cA78FbF26c0B4956C"
LB_OWNER="0x67985B1f8B613b57077bbDb24A5DEFCDDA458317"
CANONICAL_VALIDATOR="0x721C0078c2328597Ca70F5451ffF5A7B38D4E947"
CANONICAL_CONFIGURATION="0x721C001227305de5C2e5e2c531BF6BFC1278111d"
REGISTRY="0xE0A0004Dfa318fc38298aE81a666710eaDCEba5C"
REGISTRY_SALT="0x87875c76b5b42c6e3e8d99803bb01d763f4335692b3b01195b1b4f11b05a23d5"
LB_CONFIGURATION_SALT="0xc3acbbaa786d78a54a05b07c8cbf6b1791b45600a6cd19fc7e85072e91fdf542"
LB_VALIDATOR_SALT="0xe51eec6bd99318e9efbc539fc07d2e8513a08951a50ba3f188ff6be3686205d8"
ZERO_SALT="0x0000000000000000000000000000000000000000000000000000000000000000"
VALIDATOR_NAME="CreatorTokenTransferValidator"
VALIDATOR_VERSION="3"
# The value Limit Break sets on Arbitrum and the other ETH-gas L2s (0.033 ETH): above it, a
# native-value permit checks the paused state.
PAUSE_CHECK_VALUE="33000000000000000"

has_code() { [ "$(cast code "$1" --rpc-url "$RPC_URL")" != "0x" ]; }
same() { [ "$(echo "$1" | tr 'A-F' 'a-f')" = "$(echo "$2" | tr 'A-F' 'a-f')" ]; }
is_address() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
is_hex() { [[ "$1" =~ ^0x[0-9a-fA-F]+$ ]]; }
is_hash() { [[ "$1" =~ ^0x[0-9a-fA-F]{64}$ ]]; }
hash_of() {
  local h
  h="$(cast keccak "$1")"
  is_hash "$h" || die "could not hash the init code"
  echo "$h"
}
# The CREATE2 address, computed here rather than read from cast's output: keccak256 of
# 0xff, the proxy, the salt and the hash of the init code, last 20 bytes (EIP-1014). cast's
# "create2" command prints different lines in different Foundry versions.
where() {
  local init="$1" salt="$2" init_hash full
  init_hash="$(hash_of "$init")"
  full="$(cast keccak "0xff${PROXY:2}${salt:2}${init_hash:2}")"
  local at="0x${full:26}"
  is_address "$at" || die "could not compute a CREATE2 address (got '$at')"
  cast to-check-sum-address "$at" 2>/dev/null || echo "$at"
}
# A contract's creation bytecode from tools/lib/limit-break, checked to be hex before it is used.
init_code() {
  local file="$LIB/$1" code
  [ -f "$file" ] || die "$file is missing: the published creation code is not in the checkout"
  code="$(tr -d '"[:space:]' <"$file")"
  is_hex "$code" && [ "${#code}" -gt 2 ] || die "$file does not hold hex bytecode"
  echo "$code"
}
# Constructor arguments, ABI-encoded, without the 0x: they follow the creation bytecode.
args() {
  local encoded
  encoded="$(cast abi-encode "$@")"
  is_hex "$encoded" || die "could not encode constructor arguments for $1"
  echo "${encoded:2}"
}

echo "Chain 46630, RPC $RPC_URL"
if has_code "$CANONICAL_VALIDATOR"; then
  echo "Limit Break's own validator is deployed at $CANONICAL_VALIDATOR. Use that one; no copy is needed."
  exit 0
fi
has_code "$PROXY" || die "the CREATE2 deployment proxy $PROXY is not on this chain. Nothing was sent."
echo "CREATE2 proxy present at $PROXY"

if [ -n "${DEPLOYER_PRIVATE_KEY:-}" ]; then
  OWNER="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"
else
  [ -n "${DEPLOYER_ADDRESS:-}" ] || die "--check without a key needs DEPLOYER_ADDRESS set to the throwaway wallet's address"
  OWNER="$DEPLOYER_ADDRESS"
fi
is_address "$OWNER" || die "the deployer address '$OWNER' is not an address"
echo "Owner of the copy: $OWNER (the throwaway deployer)"

# The published creation code, proven: with Limit Break's salts and owner, each file must give
# the canonical address, or it is not their code and nothing is sent.
echo "Checking the creation code in tools/lib/limit-break against Limit Break's canonical addresses ..."
REGISTRY_CODE="$(init_code eoa-registry.initcode)"
CONFIGURATION_CODE="$(init_code validator-configuration.initcode)"
VALIDATOR_CODE="$(init_code transfer-validator.initcode)"
got="$(where "$REGISTRY_CODE" "$REGISTRY_SALT")"
same "$got" "$REGISTRY" || die "eoa-registry.initcode is not the published code: it would land at $got, not the canonical $REGISTRY (init code hash $(hash_of "$REGISTRY_CODE")). Nothing was sent."
got="$(where "${CONFIGURATION_CODE}$(args 'f(address)' "$LB_OWNER")" "$LB_CONFIGURATION_SALT")"
same "$got" "$CANONICAL_CONFIGURATION" || die "validator-configuration.initcode is not the published code: with Limit Break's owner it would land at $got, not the canonical $CANONICAL_CONFIGURATION. Nothing was sent."
got="$(where "${VALIDATOR_CODE}$(args 'f(address,address,string,string,address)' "$LB_OWNER" "$REGISTRY" "$VALIDATOR_NAME" "$VALIDATOR_VERSION" "$CANONICAL_CONFIGURATION")" "$LB_VALIDATOR_SALT")"
same "$got" "$CANONICAL_VALIDATOR" || die "transfer-validator.initcode is not the published code: with Limit Break's owner it would land at $got, not the canonical $CANONICAL_VALIDATOR. Nothing was sent."
echo "  all three give Limit Break's canonical addresses: this is the published code"

# Our deployment: the registry (canonical, or a copy at its own address), then the copies with
# the deployer as owner.
if [ "$OWN_REGISTRY" = 1 ]; then
  REGISTRY_SALT="$ZERO_SALT"
  REGISTRY="$(where "$REGISTRY_CODE" "$REGISTRY_SALT")"
  REGISTRY_LABEL="own copy, zero salt"
else
  REGISTRY_LABEL="canonical"
fi
REGISTRY_INIT="$REGISTRY_CODE"
CONFIGURATION_INIT="${CONFIGURATION_CODE}$(args 'f(address)' "$OWNER")"
CONFIGURATION="$(where "$CONFIGURATION_INIT" "$ZERO_SALT")"
VALIDATOR_INIT="${VALIDATOR_CODE}$(args 'f(address,address,string,string,address)' "$OWNER" "$REGISTRY" "$VALIDATOR_NAME" "$VALIDATOR_VERSION" "$CONFIGURATION")"
VALIDATOR="$(where "$VALIDATOR_INIT" "$ZERO_SALT")"

echo "  EOA registry        $REGISTRY ($REGISTRY_LABEL)"
echo "                      init code hash $(hash_of "$REGISTRY_INIT")"
echo "  configuration copy  $CONFIGURATION"
echo "                      init code hash $(hash_of "$CONFIGURATION_INIT")"
echo "  validator copy      $VALIDATOR"
echo "                      init code hash $(hash_of "$VALIDATOR_INIT")"

if [ "$CHECK_ONLY" = 1 ]; then
  echo "Check only. Nothing was sent."
  exit 0
fi

# The proxy takes the salt followed by the init code, and deploys with CREATE2.
deploy() {
  local name="$1" at="$2" salt="$3" init="$4"
  if has_code "$at"; then
    echo "  $name already at $at"
    return
  fi
  echo "  deploying $name ..."
  cast send "$PROXY" "0x${salt:2}${init:2}" --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$RPC_URL" >/dev/null
  has_code "$at" || die "$name did not appear at $at after the transaction"
  echo "  $name deployed at $at"
}
deploy "EOA registry" "$REGISTRY" "$REGISTRY_SALT" "$REGISTRY_INIT"
deploy "configuration copy" "$CONFIGURATION" "$ZERO_SALT" "$CONFIGURATION_INIT"
if ! cast call "$CONFIGURATION" "getNativeValueToCheckPauseState()(uint256)" --rpc-url "$RPC_URL" >/dev/null 2>&1; then
  echo "  initialising the configuration copy ..."
  cast send "$CONFIGURATION" "setNativeValueToCheckPauseState(uint256)" "$PAUSE_CHECK_VALUE" --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$RPC_URL" >/dev/null
fi
deploy "validator copy" "$VALIDATOR" "$ZERO_SALT" "$VALIDATOR_INIT"

echo
echo "Done. The rehearsal's transfer validator is at $VALIDATOR on testnet (not Limit Break's canonical"
echo "$CANONICAL_VALIDATOR, which only Limit Break can deploy). Record this address."
echo "Next, from the token's owner wallet, switch it on:"
echo "  cast send <token address> \"setTransferValidator(address)\" $VALIDATOR --private-key <owner key> --rpc-url \$RPC_URL"
