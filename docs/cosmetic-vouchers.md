# Cosmetic vouchers: what the game server needs

A holder applies a cosmetic to a revealed Genesis token with `applyTrait(tokenId, category, layer, proof)` on the token, from their own wallet and paying their own gas. The token asks its trait authority, `CosmeticVoucherAuthority`, whether they own that cosmetic. The proof is a voucher the game server signed with its cosmetics key. This page is what the server side has to build to issue them. Nothing here is built in the game yet.

## The flow

1. The player picks a cosmetic they own in the game and a revealed token they hold.
2. The game server checks, from its own records, that the wallet owns that cosmetic, that it is not already held for another voucher, that the token may wear it (see Class-specific cosmetics below) and that the cosmetic is not sold out on chain. It **holds** the cosmetic against a fresh voucher id. Holding is not burning: the cosmetic stays the player's, it just cannot back a second voucher.
3. The server signs the voucher and returns the voucher and the signature to the client.
4. The client sends `applyTrait(tokenId, category, layer, proof)` from the player's wallet. The player signs only that transaction; the voucher signature is the server's. Because the voucher is EIP-712 typed data, any wallet or tool that signs or inspects one (a hardware wallet signing in the rehearsal, a block explorer, a support check) shows its fields in plain words.
5. The authority checks the voucher and emits `VoucherSpent(voucherId, player, tokenId, category, layer)`; the token emits `TraitApplied(tokenId, category, layer, player)` and `MetadataUpdate(tokenId)`. A refused apply emits nothing and spends nothing.
6. The server burns the cosmetic only when it sees that confirmation, never before (below).

## Burn only on confirmation

The game never burns a cosmetic because it signed a voucher, or because the client says the transaction went through. It burns on the chain's word alone:

- **The event.** `VoucherSpent(voucherId, player, tokenId, category, layer)` from the authority the token currently uses (`token.traitAuthority()`). `voucherId` is indexed, so the server finds its voucher with one log filter.
- **The match.** The server looks up its held voucher by `voucherId` and checks the event's `player`, `tokenId`, `category` and `layer` against what it signed. Anything that does not match is logged and burns nothing.
- **Confirmed.** It waits until the block carrying the event is final on the chain (for the testnet, a set number of blocks behind the head, a config value), so a reorg can never leave a burn without an applied trait.
- **The burn.** Then, and only then, it appends the ledger entry that spends the cosmetic, keyed by the voucher id so the same event can never burn twice, and marks the voucher spent.
- **Expiry.** A voucher whose `expiresAt` passes with no event releases its hold, as a ledger entry too; the cosmetic is the player's to use again. The server issues a fresh id next time and never reuses the old one.
- **How the server sees it.** A cron sweep reads the authority's `VoucherSpent` logs from the last block it processed, plus a check when the player returns to the game after applying, the same lazy-plus-sweep pattern as the game's timers. A voucher id the server never issued is ignored.

So a cosmetic is in exactly one of three states: owned, held for one voucher (until it is spent on chain or expires), or burned because the chain confirmed it was applied.
## Class-specific cosmetics

Most cosmetics fit any character. A class-specific cosmetic (a Hacker's visor, an Enforcer's jacket) fits only an Operator of that class (the spec's Cosmetics section).

- **Where it is enforced: at signing.** The voucher names one token, so the game server signs a voucher for a class-specific cosmetic only when that token is an Operator of the cosmetic's class, read from the game's own record of the token's class. A Genesis has no class, so it never gets one. Any other request is refused before anything is held or signed, in plain words ("This visor fits Hackers only.").
- **Why that is enough on Genesis.** The Genesis contract knows nothing of classes and needs nothing: the authority accepts only vouchers the cosmetics key signed, and the key signs only eligible ones. No change to the token.
- **The off-class find.** The cosmetic stays the player's: sold at the Market, swapped at the Fence, or kept for an Operator of the right class. Nothing is held or burned for a refused request.
- **For the Operators contract (recorded for when it is built).** Operators carry their class from mint, so that contract can also enforce it on chain, so a backend bug or a compromised key cannot put a class-specific cosmetic on the wrong class. The design to build then: the token stores each Operator's class (one byte, written at mint or reveal from the committed trait table, never changed); the renderer's `addLayers` takes a class per cosmetic beside its cap (0 for any class, otherwise the one class it fits), fixed at upload like the cap and readable by anyone; and `applyTrait` refuses a cosmetic whose class is set and differs from the token's (`WrongClass(tokenId, class, cosmeticClass)`). The voucher, the authority and the server's check stay as they are, so the server refuses first and the chain refuses as a backstop. The class byte and the per-cosmetic class are a few hundred bytes; the Operators token is a fresh contract with its own size budget.

## The project pays the gas (built, off)

By default the player sends `applyTrait` and pays its gas. A second path, where the project pays, is built and switched off:

- **Off twice.** The token takes `applyTraitFor(player, tokenId, category, layer, proof)` only from its `sponsor`, which is zero until the token's owner calls `setSponsor(<SponsoredApplier>)`; and `SponsoredApplier` refuses everything (`SponsoringOff`) until its owner calls `setEnabled(true)`, and then only from relayers its owner added (`setRelayer`).
- **The player still decides.** They sign an EIP-712 `Request(address player,uint256 tokenId,uint256 category,uint256 layer,bytes32 proofHash,uint256 deadline)` in domain `Nightfall Sponsored Apply` / `1` (verifying contract: the `SponsoredApplier`). `proofHash` is `keccak256` of the exact voucher proof, so a relayer cannot swap in another voucher. No transaction from their wallet, no gas. Smart-contract wallets sign through ERC-1271.
- **The relayer pays.** A project wallet holding a little gas money calls `submit(request, proof, playerSignature)`. The token runs every check `applyTrait` runs, with the player in place of the sender (holds the token, cap not reached, the voucher the game's for this wallet, token and cosmetic, unspent), so the voucher is spent and the same request never works twice. The same events fire, plus `SponsoredApply(player, tokenId, category, layer, relayer)`.
- **Turning it on** (a decision for later, not now): deploy `SponsoredApplier(token)`, `setRelayer(<relayer>, true)`, `setEnabled(true)`, then `setSponsor(<applier>)` on the token. **Off again:** `setSponsor(address(0))` on the token, or `setEnabled(false)` on the helper; either stops it at once.
- **Size.** The token carries only the entry point and the sponsor address (about 370 bytes); the signature checking lives in the helper, so the token keeps its margin under the 24,576-byte limit.

## The message (EIP-712)

Domain:

| Field | Value |
|---|---|
| `name` | `Nightfall Cosmetics` |
| `version` | `1` |
| `chainId` | the chain's id (46630 testnet, 4663 mainnet) |
| `verifyingContract` | the `CosmeticVoucherAuthority` address, not the token's |

Type, primary type `Voucher`:

```
Voucher(address player,uint256 tokenId,uint256 category,uint256 layer,uint256 voucherId,uint256 expiresAt)
```

| Field | Meaning |
|---|---|
| `player` | the wallet that will send `applyTrait` |
| `tokenId` | the token the cosmetic goes on |
| `category` | the trait category index in the renderer (Headwear is 5) |
| `layer` | the cosmetic's layer index in that category, as `addLayers` returned it |
| `voucherId` | a one-time id: a random 256-bit number, never reused, whoever it was for |
| `expiresAt` | a unix time in seconds; the voucher works up to and including this second |

`authority.voucherDigest(voucher)` and `authority.domainSeparator()` return what the contract expects, so the server's signing code can be checked against a deployed authority with a read call.

## The proof

The last argument of `applyTrait` is:

```
abi.encode(voucher, signature)
```

where `voucher` is the tuple `(address,uint256,uint256,uint256,uint256,uint256)` in the field order above and `signature` is the 65-byte `r || s || v` the signer returns (`bytes`). With viem, `signTypedData` from the server's account gives the signature and `encodeAbiParameters` builds the proof. `script/TraitUpgrade.s.sol`'s `voucher` function builds the same proof with Foundry and is a worked reference.

## What the contract refuses

Each refusal is its own error, so the client can say what went wrong:

| Error | When |
|---|---|
| `VoucherExpired(voucherId, expiresAt)` | the block time is past `expiresAt` |
| `VoucherAlreadyUsed(voucherId)` | the id was spent before |
| `VoucherForAnotherWallet(voucherPlayer, player)` | the sender is not the voucher's wallet |
| `VoucherForAnotherToken(voucherTokenId, tokenId)` | the token is not the voucher's |
| `VoucherForAnotherCosmetic(...)` | the category or layer is not the voucher's |
| `NotSignedByCosmeticsKey(recovered)` | not signed by the current cosmetics key, or the voucher was edited after signing |

The token's own checks come first: `UpgradesOff`, `NotRevealed`, `NotTokenHolder`, `NoSuchTrait`, then the supply cap: `NotACosmetic(category, layer)` for a base mint layer, which is never applied, and `CosmeticSoldOut(category, layer, cap)` once as many tokens have had that cosmetic applied as its cap allows. Every cosmetic's cap is set when it is uploaded (`addLayers(category, blob, names, caps)`, one cap per layer, at least 1) and never changes; `renderer.cosmeticCap(category, layer)` and `token.cosmeticApplied(category << 16 | layer)` give what is left, so the server never signs a voucher for a sold-out cosmetic. A refused apply spends nothing, and the voucher stays unspent until it expires.

## Expiry and ids

Short expiries: minutes, long enough for the player to confirm the transaction. A short expiry bounds how long a leaked voucher is useful, and lets the server release a reservation soon after. The server stores every id it issues with its reservation, so an id is never issued twice.

## The key

- **Its own key.** A dedicated cosmetics signing key, used for nothing else: never the token's owner, never the lock operator's key, never the deployer's. The contract refuses the token's owner, the token's operator and the authority's owner as the signer, at setup, at every swap and at every use.
- **Where it lives.** Only in the game server's secret store: the hosting provider's encrypted environment variables, production scope only, or a KMS key the server signs with, which keeps the key out of the server's memory entirely. Never in the repo, never in `.env.example` with a value, never in the client, never in logs.
- **Testnet.** A separate throwaway key per environment. The mainnet key is made fresh for mainnet and never used on testnet.
- **The key holds no funds and sends no transactions.** It only signs; the player pays the gas.
- **The swap.** If the key may have leaked, the authority's owner calls `setSigner(<new address>)`. It takes effect in that block: every unused voucher the old key signed stops working at once, and only the new key's vouchers are accepted. The server then signs with the new key; anything it issued before the swap has to be reissued.
- **Turning upgrades off.** The token's owner can call `setTraitAuthority(address(0))`, which refuses every `applyTrait` until an authority is set again.

## Setup, per chain

1. Make the cosmetics key and put its private key in the server's secret store.
2. Deploy `CosmeticVoucherAuthority(token, <cosmetics key address>)` from the owner wallet and call `setTraitAuthority(<authority>)` on the token (`TraitUpgrade.s.sol`'s `enable` does both on testnet).
3. Give the server the authority's address and the chain id, for the domain.
4. Check with a read call that `voucherDigest` of a sample voucher matches what the server's code hashes.
