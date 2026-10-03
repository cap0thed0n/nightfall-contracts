# Nightfall City contracts

[![tests](https://github.com/cap0thed0n/nightfall-contracts/actions/workflows/test.yml/badge.svg)](https://github.com/cap0thed0n/nightfall-contracts/actions/workflows/test.yml)

Nightfall City is a pixel-art crime game on Robinhood Chain. Players hold Genesis bosses and Operators, send them on Expeditions and Missions across the city, and come back with credits, items, Heat and, now and then, a real-world reward paid in tokenised stock. Play it at [play.nightfallcity.com](https://play.nightfallcity.com).

This repository is the on-chain side: the Genesis collection contract, the renderer that draws every token from layers stored on chain, the authority that lets a holder upgrade a token's look with a signed voucher, and the tools that check the art and run the deploy. The game server is a separate codebase; everything it needs from the chain is here.

## How the contracts fit the game

- **Who holds what.** The game reads Genesis ownership from the contract (`tokensOfOwner`, `ownerOf`), never from its own database, so a Genesis bought, sold or sent plays for its new holder at once. While a character is out on a run, the game's operator wallet sets an expiring lock on the token (`lockUntil`), and the token cannot be transferred until the run is back.
- **The art and the reveal.** Every token's image and metadata are composed on chain by `NightfallRenderer` from 16 x 16 trait layers stored with SSTORE2, and served as a data URI: no server, no IPFS. Before the reveal every token shows one animated pre-reveal picture. The trait table is committed ahead of the mint, the reveal offset comes from a block hash captured after minting closes, and nobody, the owner included, can choose or redo it.
- **Cosmetic upgrades.** A cosmetic a player earns in the game is applied to their revealed token by the holder themself (`applyTrait`), checked by `CosmeticVoucherAuthority`: an EIP-712 voucher the game's dedicated cosmetics key signs for one wallet, one token and one cosmetic, used once before it expires. The applied cosmetic replaces its category's trait in the metadata and the image, and the token emits `MetadataUpdate` so marketplaces and the game refresh.
- **RWA rewards.** A Mission that hits its reward roll pays the player in one of Robinhood Chain's tokenised stocks. That is a plain ERC-20 transfer from the game's payer wallet to the player's wallet, sized and recorded by the game server; no contract in this repository holds or moves those tokens. The contracts' part is the Genesis that earned it.

## On Robinhood Chain testnet

The live rehearsal, with placeholder art, on Robinhood Chain testnet (chain id 46630, RPC `https://rpc.testnet.chain.robinhood.com`):

| Contract | Address |
|---|---|
| `NightfallGenesis` | [`0x2a4b2257fc93265e0886e82d5f83ef8b706f2625`](https://explorer.testnet.chain.robinhood.com/address/0x2a4b2257fc93265e0886e82d5f83ef8b706f2625) |
| `NightfallRenderer` | [`0x671e26a2bea5b8c494865ac7e3c0bc02220342c7`](https://explorer.testnet.chain.robinhood.com/address/0x671e26a2bea5b8c494865ac7e3c0bc02220342c7) |
| `CosmeticVoucherAuthority` | [`0x01c298A3001F061d9a70e882DFCC11DB6153253B`](https://explorer.testnet.chain.robinhood.com/address/0x01c298A3001F061d9a70e882DFCC11DB6153253B) |

`deploy/testnet.json` is the config that deploy ran from, with one change: its `artFile` entry is a note in place of the path, since the Genesis art export is supplied separately and is not in this repository (the tests use the fixture art instead). Mainnet (chain id 4663) is not deployed.

## What is where

| Folder | What it holds |
|---|---|
| `src/` | The contracts. `NightfallGenesis.sol` (the collection, an `ERC721SeaDrop` with locks, the commit-reveal and cosmetic upgrades), `NightfallRenderer.sol` (the on-chain art), `authority/` (the voucher authority and the optional project-pays-gas applier), `interfaces/`, `lib/LayerSet.sol` (the byte layout of a layer set), `art/PlaceholderArt.sol` (generated test shapes, never the real art) |
| `test/` | The Foundry suite: 184 tests across the token, the renderer, the reveal, the locks, the cosmetics, the vouchers, the art export and the deploy |
| `script/` | The deploy (`DeployTestnet.s.sol`, driven by `deploy/testnet.json`), the art export loader and checker (`ArtFile.sol`, `VerifyExport.s.sol`), the per-token gas report (`ArtReport.s.sol`) and the local chain the game's own tests run against (`LocalGame.s.sol`) |
| `tools/` | Node scripts with no dependencies: the independent art compositor that checks every token picture (`art-check.mjs`), the placeholder art generator, the reveal sheet, the testnet transfer-validator deploy, and their tests under `tools/test/` |
| `deploy/` | The deploy config, the pre-reveal animation and the fixture art the tests use |
| `docs/` | `owner-powers.md` (who can do what to the deployed contracts) and `cosmetic-vouchers.md` (the voucher format a server signs) |
| `lib/` | Dependencies: six git submodules pinned to the commits SeaDrop pins, and SeaDrop itself vendored with one documented change (`lib/seadrop/VENDORED.md`). Licences in `THIRD-PARTY.md` |

Solidity 0.8.17 throughout, because SeaDrop pins it.

## Run the tests

From a fresh clone, with [Foundry](https://getfoundry.sh) and Node 20 or newer installed:

```
git clone --recurse-submodules https://github.com/cap0thed0n/nightfall-contracts.git
cd nightfall-contracts
forge test
node --test tools/test/*.test.mjs
```

More, when wanted:

```
FOUNDRY_PROFILE=ci forge test                                                        # 4096 fuzz runs
forge script script/VerifyExport.s.sol --sig "run(string)" deploy/art/fixture-genesis.json   # the art export through the renderer
slither . --filter-paths "lib/|test/|script/" --exclude-dependencies
aderyn . --src src/
```

The same two suites run on every push and pull request (`.github/workflows/test.yml`); the badge at the top is their latest result.

## Who can do what

[`docs/owner-powers.md`](docs/owner-powers.md) lists every power over the deployed contracts, with its limits, whether it can be undone and whether it touches existing art. The short version:

| Role | Can | Cannot |
|---|---|---|
| The owner (a 2-of-3 Safe before mainnet) | Swap the renderer and the trait authority, name the operator and the sponsor, set the lock ceiling and royalties, close the mint, commit the reveal, upload cosmetic layers, load and replace the base art until frozen | Mint after the close, change the supply or the pre-reveal picture after the first mint, pick or redo the reveal, take, burn or move a token, raise a cosmetic's cap |
| The operator (the game's server wallet) | Hold a token still until a timestamp, at most the ceiling ahead | Anything else: no transfer, burn, upgrade or metadata change |
| The cosmetics authority (and its dedicated signer) | Say yes or no to a holder applying one cosmetic to their own revealed token | Apply anything a holder did not ask for; sign with the owner's or the operator's key |
| Anyone | `captureEntropy` once the target block has passed, `reveal` with the secret, `applyTrait` on their own token | |

The renderer is never frozen: the tokens are meant to stay dynamic, so `setRenderer` and the base-art calls remain, under the Safe on mainnet. `renounceOwnership` is never called.

## License

The code is MIT ([`LICENSE`](LICENSE)). The art, music, logos and the Nightfall City name and brand are not: they are all rights reserved, on chain included, and [`ASSETS.md`](ASSETS.md) says so in full. Third-party code under `lib/` and `tools/lib/` keeps its own licence ([`THIRD-PARTY.md`](THIRD-PARTY.md)).
