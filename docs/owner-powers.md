# Who can do what to the Genesis contract

A plain account of every power over the Nightfall Genesis contract (`NightfallGenesis`, its renderer `NightfallRenderer` and the cosmetics authority `CosmeticVoucherAuthority`), for collectors and judges. Three roles hold powers: the **owner** (the deployer's wallet, until handed over), the **operator** (the game's server wallet, which sets locks) and the **cosmetics authority** (the contract that confirms a holder owns a cosmetic, and the signer behind it). Everything else is held by nobody.

Powers come from the contracts as deployed on the testnet rehearsal. "Lockable" means a way exists to give the power up for good; "undoable" means the change can be reversed later by the same role.

## The owner

| Power | What it changes | Limits | Undoable | Lockable | Touches existing art or metadata |
|---|---|---|---|---|---|
| `setMaxSupply` | The collection's size | Refused once the first token is minted, up, down or to the same value | Before the first mint only | By the first mint | No |
| `setProvenanceHash` | The hash of the art table | Refused once the first token is minted (SeaDrop) | Before the first mint only | By the first mint | No |
| `commitReveal` | The commitment the reveal secret must match | Once; refused after | No | By itself | No |
| `closeMint` | Ends minting, fixes the reveal's target block 30 blocks ahead | Once; a sell-out does the same by itself | No | By itself | No |
| `setRenderer` | Which contract draws every token | None after launch | Yes, by setting another | **No** | **Yes: every token's image and metadata, at once** (`BatchMetadataUpdate`) |
| `setTraitAuthority` | Which contract may confirm cosmetics; zero turns upgrades off | None | Yes | No | No, but decides whether holders can change their own |
| `setSponsor` | Which contract may apply cosmetics on a holder's behalf (gas paid for them) | Every check of a holder's own apply still runs | Yes | No | No |
| `setOperator` | Which wallet may lock tokens | None | Yes | No | No |
| `setMaxLockSeconds` | The longest a lock may run (26 hours on the rehearsal) | Must be above zero | Yes | **No** | No, but a very long ceiling would let the operator hold tokens still |
| `setRoyaltyInfo` | Royalties and their receiver (SeaDrop) | None | Yes | No | No |
| `setBaseURI`, `setContractURI` | Fallback metadata URLs (SeaDrop) | Unused while a renderer is set; the renderer answers `tokenURI` | Yes | No | Only if the renderer were removed |
| `updatePublicDrop`, `updateAllowList`, `updateTokenGatedDrop`, `updateDropURI`, `updateCreatorPayoutAddress`, `updateAllowedFeeRecipient`, `updateSignedMintValidationParams`, `updatePayer`, `updateAllowedSeaDrop` | The mint's terms and where mint money goes (SeaDrop) | Meaningless once the mint is closed | Yes | By closing the mint | No |
| `setTransferValidator` | A transfer validator contract (SeaDrop) | None | Yes | No | No, but could restrict transfers |
| `transferOwnership` (two-step) | Hands every owner power to another wallet, which must accept | None | Only by the new owner | By handing to a multisig or renouncing | No |
| On the renderer: `addCategory`, `replaceCategory`, `setTable`, `setTierColours` | The base art, the trait table, the tier colours | **Refused once frozen** | Until frozen | **Yes, `freeze`** | **Yes, until frozen** |
| On the renderer: `freeze` | Makes the base art final for good | Needs the table set; once. **Not used: the tokens stay dynamic** | No | Is the lock | No |
| On the renderer: `addLayers` | Appends new cosmetic layers to a category, each with a supply cap fixed at upload | Allowed after the freeze; caps can never be raised | No (a layer cannot be removed) | No, by design: upgrades keep working | No: a new layer changes no token until a holder applies it |
| On the renderer: `setPreRevealImage` | The picture every token shows before the reveal | **Refused once the first token is minted** | Before the first mint only | By the first mint | No |
| On the renderer: `bindToken` | Which token the renderer draws | Once | No | By itself | No |
| On the authority: `setSigner` | The key that signs cosmetic vouchers | Never the owner's, the operator's or the deployer's key | Yes | No | No |

## The operator

| Power | What it changes | Limits | Undoable | Touches existing art or metadata |
|---|---|---|---|---|
| `lockUntil` | Holds a token still (no transfer) until a timestamp, per token | At most `maxLockSeconds` ahead of now; a time at or before now lifts the lock; refused for a token that does not exist | Yes, by setting an earlier time | No |

The operator can never take, burn, upgrade or alter a token, only stop it moving for up to the ceiling.

## The cosmetics authority

| Power | What it changes | Limits | Touches existing art or metadata |
|---|---|---|---|
| `authorize` | Says yes or no to one holder applying one cosmetic to one of their own tokens | Only when the holder asks (`applyTrait`) or the sponsor asks for them; the token must be revealed and held by that player; the layer must be a cosmetic with supply left; a voucher is signed for one player, token, category, layer and expiry | Yes, but only the token whose holder asked, and only the trait category the cosmetic covers |

## What nobody can do

- Mint after the close: `closeMint` and a sell-out end minting for good; every later mint reverts.
- Change the supply: refused from the first mint on, by the override in `NightfallGenesis`.
- Change a reveal: the commitment is set once; the entropy is a block hash captured by anyone once the target block has passed, and the reveal is derived from both; the owner cannot pick or redo it.
- Change the pre-reveal picture after the first mint.
- Change the base art, the table or the renderer without the owner: on mainnet, two of the Safe's three signers.
- Take a token, burn a token, move a token, or freeze a token for good: there is no owner path to transfer or burn, and a lock cannot exceed the ceiling.
- Raise a cosmetic's supply cap, or remove a cosmetic once applied.
- Apply a cosmetic to a token its holder did not ask for.
- Pay with a voucher signed by the owner's or the operator's key: the authority refuses a signer that is not dedicated.

## Powers that could change existing art or metadata after launch

1. **`setRenderer`** (owner): points every token at another renderer. This is the one power that can change every image and every trait at once. **Decision: it stays.** The tokens are meant to be dynamic and upgradeable, so the renderer is never frozen and `setRenderer` is kept, under the multisig on mainnet: a renderer swap is a published, 2-of-3 decision, never one key's.
2. **The unfrozen renderer** (owner): `freeze` exists in the contract but is not called. The base art, the table and the tier colours stay replaceable by the owner, which on mainnet is the multisig. Same rule as the renderer swap: a published, 2-of-3 decision.
3. **`setMaxLockSeconds`** (owner): a far higher ceiling would let the operator hold tokens still for long stretches. Not art, but a holder's use of the token. Under the multisig.
4. **`setRoyaltyInfo`** (owner): changes what marketplaces collect and for whom. Under the multisig.
5. **`setTraitAuthority` and `setSponsor`** (owner): cannot change a token by themselves, but choose who confirms upgrades. A malicious authority could only ever approve what a holder themself asked for. Under the multisig, with the authority address published.

## Exactly which actions need the owner

Everything the owner can do, in one list, because ownership moves to a 2-of-3 Safe before mainnet and each of these then needs two signatures:

- **On the token:** `setRenderer`, `setTraitAuthority`, `setSponsor`, `setOperator`, `setMaxLockSeconds`, `commitReveal`, `closeMint`, `setMaxSupply` (before the first mint), `setProvenanceHash` (before the first mint), `setRoyaltyInfo`, `setBaseURI`, `setContractURI`, `setTransferValidator`, every SeaDrop `update...` (the mint's terms and payouts), `transferOwnership` (two-step: the new owner accepts).
- **On the renderer:** `addCategory`, `replaceCategory`, `setTable`, `setTierColours`, `bindToken`, `setPreRevealImage` (before the first mint), `freeze` (not used), and **`addLayers`: uploading cosmetic layers is owner-only.** Every new cosmetic is a Safe transaction, so cosmetics are uploaded in batches (one `addLayers` call carries any number of layers for a category), planned ahead, never on demand.
- **On the voucher authority:** `setSigner`, `transferOwnership`.

## What keeps working with no owner signature

The game runs day to day on three keys that are not the owner and never need the Safe:

| Key | Where it signs | What it does | Owner needed |
|---|---|---|---|
| The operator | On chain, `lockUntil` on the token | Locks and unlocks characters as runs start and end | No. The owner only names it (`setOperator`), once |
| The payer | On chain, ERC-20 `transfer` of the stock tokens | Pays RWA rewards from its own holdings | No. It holds no power over the Genesis contract at all |
| The cosmetics signer | Off chain, EIP-712 vouchers | Signs a voucher for one holder, one token, one cosmetic; the holder sends `applyTrait` and the token asks the authority, which checks the signature | No. The owner only names it (`setSigner`), once |

`captureEntropy` and `reveal` are anyone's: the first by anyone once the target block has passed, the second by anyone who knows the secret. The holder's own `applyTrait` and the sponsor's `applyTraitFor` need no owner either.

## The mainnet ownership plan

1. **Deploy from a deployer wallet** (a hardware wallet or an encrypted keystore): the token, the renderer, the voucher authority. Load the art, set the table, bind the token, set the pre-reveal image, set the operator, the trait authority and the sponsor, commit the reveal. All of this is one key's work, before any token exists.
2. **Hand ownership to the Safe, 2 of 3**, before the mint opens: on the token, `transferOwnership(safe)` then `acceptOwnership()` from the Safe (two-step); on the renderer and the authority, `transferOwnership(safe)` (OpenZeppelin's one-step `Ownable`: check the address twice, there is no accepting side). Publish the Safe's address and its three signers' roles.
3. **From then on,** every owner action in the list above is a Safe transaction with two signatures: `closeMint` if the mint does not sell out, each batch of cosmetic uploads, any renderer or art change, any change of operator, authority, sponsor, lock ceiling or royalties.
4. **The three gameplay keys stay plain wallets on the game's server**, named once by the owner before the handover: they need no signature from the Safe, ever. Rotating one is a Safe transaction (`setOperator`, `setSigner`); the payer rotates by funding a new wallet.
5. **Never renounce.** `renounceOwnership` exists on all three contracts; with it, no renderer could ever be swapped and no cosmetic ever added. The Safe keeps ownership.
