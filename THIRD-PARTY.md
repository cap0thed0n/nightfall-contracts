# Third-party code

Everything under `lib/` is someone else's work, used under its own licence, listed here. This repository's own code is MIT (`LICENSE`); its art, music and brand are not licensed at all (`ASSETS.md`).

| Path | Project | Pinned at | Licence |
|---|---|---|---|
| `lib/seadrop` | [ProjectOpenSea/seadrop](https://github.com/ProjectOpenSea/seadrop), `src/` and `LICENSE` only, vendored with one change (`setMaxSupply` declared `virtual`; see `lib/seadrop/VENDORED.md`) | commit `757590f11babfd81f4608f736e79e388469377f2` | MIT (Ozone Networks, Inc.) |
| `lib/ERC721A` | [chiru-labs/ERC721A](https://github.com/chiru-labs/ERC721A) | submodule, v4.2.2 (`9be81f0`) | MIT (Chiru Labs) |
| `lib/openzeppelin-contracts` | [OpenZeppelin/openzeppelin-contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | submodule, 4.7.0 (`6a8d977`) | MIT (zOS Global Limited and contributors) |
| `lib/solmate` | [transmissions11/solmate](https://github.com/transmissions11/solmate) | submodule (`01a5235`) | AGPL-3.0-only |
| `lib/utility-contracts` | [jameswenzel/utility-contracts](https://github.com/jameswenzel/utility-contracts) | submodule (`6543a1d`) | MIT (per the SPDX header on every source file) |
| `lib/forge-std` | [foundry-rs/forge-std](https://github.com/foundry-rs/forge-std) | submodule, after v1.16.2 (`3e2295d`) | MIT or Apache-2.0 |
| `lib/sstore2` | [0xsequence/sstore2](https://github.com/0xsequence/sstore2) | submodule (`0a28fe6`) | MIT (Ismael Ramos Silvan) |
| `tools/lib/limit-break/*.initcode` | Limit Break's published creation code for its creator-token transfer validator, EOA registry and validator configuration, as recorded on chain; `tools/lib/limit-break/README.md` says how each is proven against the canonical deployments | creator-token-standards v3.0.0 (`14eb0cb`) | MIT (Limit Break, Inc.), as that repository licenses it |

The six submodules are pinned to the commits SeaDrop itself pins and are unmodified. `solmate` is reached only through SeaDrop's and ERC721A's imports at compile time; its AGPL terms apply to it, not to this repository's own sources.

`deploy/art/prereveal/pre-reveal160x.gif` and `deploy/art/fixture-genesis.json` are this project's own: the pre-reveal picture every unrevealed token serves, and generated test shapes. Neither is the Genesis art, and neither is under MIT: see `ASSETS.md`.
