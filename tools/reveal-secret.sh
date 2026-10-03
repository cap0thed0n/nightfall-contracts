#!/usr/bin/env bash
# Makes the reveal secret and its commitment. Run on the deploying machine only, once per deployment. Prints a
# sheet to copy or print, and writes the commitment (never the secret) straight into the deploy
# config named, so nothing from the sheet is ever copied by hand. Never paste the sheet into a
# chat, a session, a cloud drive or a screenshot. The commitment alone is safe to share.
#
#   bash tools/reveal-secret.sh deploy/mainnet.json
#
# The config's revealCommitment must still be the zero value; a config already committed is left
# alone (pass --replace to overwrite it, for a fresh deployment of the same config).
set -euo pipefail
CONFIG="${1:-}"
REPLACE="${2:-}"
if [ -z "$CONFIG" ]; then echo "usage: bash tools/reveal-secret.sh deploy/<config>.json [--replace]"; exit 1; fi
[ -f "$CONFIG" ] || { echo "no such config: $CONFIG"; exit 1; }
grep -q '"revealCommitment": "0x[0-9a-fA-F]\{64\}"' "$CONFIG" || { echo "$CONFIG has no revealCommitment line to fill"; exit 1; }
if ! grep -q '"revealCommitment": "0x0\{64\}"' "$CONFIG" && [ "$REPLACE" != "--replace" ]; then
  echo "$CONFIG already holds a commitment. For a fresh deployment of this config run again with --replace; otherwise leave it, the sheet for it already exists."
  exit 1
fi
command -v cast >/dev/null 2>&1 || { echo "cast is missing: install Foundry first (foundryup), then reopen the terminal"; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is missing"; exit 1; }

SECRET="0x$(openssl rand -hex 32)"
COMMIT="$(cast keccak "$SECRET")"
CHECK="${COMMIT:2:8}"
GROUPED="$(echo "${SECRET:2}" | fold -w8 | paste -sd' ' -)"
# The commitment into the config, by itself: the secret is never written anywhere.
sed -i "s/\"revealCommitment\": \"0x[0-9a-fA-F]\{64\}\"/\"revealCommitment\": \"$COMMIT\"/" "$CONFIG"
grep -q "\"revealCommitment\": \"$COMMIT\"" "$CONFIG" || { echo "could not write the commitment into $CONFIG"; exit 1; }

cat <<SHEET

============================================================================
 NIGHTFALL GENESIS REVEAL SHEET        made $(date -u +%Y-%m-%d) UTC
 chain: ____________  token address: ____________________________________
============================================================================

 SECRET (64 hex digits, 8 groups of 8). Digits 0-9 and letters a-f only:
 0 is always the number zero, never the letter O; 1 is never the letter l.

   0x $GROUPED

 CHECKSUM (the first 8 characters of the commitment): $CHECK

 COMMITMENT (already written into $CONFIG as revealCommitment; safe to share):
   $COMMIT

 Anything you ever paste from the deploy config must start with 0x$CHECK and be
 64 hex characters after the 0x: that is the commitment. The secret is only on
 this sheet, never in any file.

----------------------------------------------------------------------------
 ON REVEAL DAY, from this sheet, in a terminal in the contracts folder:

 1. Type the secret from the sheet without the spaces, as one word after 0x,
    and check it before sending anything:

      cast keccak 0x<the 64 digits>

    The answer must start with 0x$CHECK. If it does not, a digit is wrong;
    find it and retype. Nothing has been sent yet.

 2. Send the reveal. Any funded wallet works; it does not need the owner key:

      cast send <token address> "reveal(bytes32)" 0x<the 64 digits> \\
        --rpc-url <rpc url> --account <keystore name>

    A wrong secret only reverts with WrongSecret and costs a little gas.
    Revealing again after success reverts with AlreadyRevealed.
============================================================================

SHEET
