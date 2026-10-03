# Limit Break's published creation code, v3.0.0

The exact creation bytecode of the three contracts `tools/lb-validator-testnet.sh` deploys for the rehearsal, from Limit Break's `creator-token-standards` at the `v3.0.0` tag (commit `14eb0cb8d486692e8b522d46cc2a06eea800286a`), without constructor arguments:

| File | Contract | Init code hash |
|---|---|---|
| `eoa-registry.initcode` | `src/utils/EOARegistry.sol:EOARegistry` | `0x347bec760e024f59d769d12e595802db14444c6db9409860019c51d1965e05e4` |
| `validator-configuration.initcode` | `src/utils/CreatorTokenTransferValidatorConfiguration.sol:CreatorTokenTransferValidatorConfiguration` | `0xbed7fd8ab703ad5c7f113bd5ebbe25f1b982a10fead61fb08d4625c068f5fb58` |
| `transfer-validator.initcode` | `src/utils/CreatorTokenTransferValidator.sol:CreatorTokenTransferValidator` | `0xb0e9a5d8eb731a81e7d8802c5f6fc0d6cc4b398425e3aa673a11ffc35766b652` |

**Why they are vendored.** Building the code locally gives a different bytecode on different machines. The compiler appends a hash of its metadata to the bytecode, and that metadata includes the build's remappings; Foundry 1.8 writes context-scoped remappings with the clone's absolute path, so the hash, the init code and every CREATE2 address change with the Foundry version and the path. The code here was built once with Foundry 1.3.5 (solc 0.8.24, cancun, 777 optimizer runs, Limit Break's `foundry.toml`), which writes the same remappings Limit Break's own build did, and it reproduces their deployments exactly.

**How the script proves it.** Before sending anything, the script computes the CREATE2 address each file would give with Limit Break's own salts and owner (`.env.common` in their repository) and requires their three canonical addresses: the EOA registry `0xE0A0004Dfa318fc38298aE81a666710eaDCEba5C`, the configuration `0x721C001227305de5C2e5e2c531BF6BFC1278111d` and the validator `0x721C0078c2328597Ca70F5451ffF5A7B38D4E947`. An address is the hash of the init code, so a file that gives the canonical address holds the published code byte for byte.

**To regenerate** (only if Limit Break's tag moves, which the script would notice): clone the repository at the tag with submodules, build with a Foundry whose metadata matches (1.3.5 does), then for each contract `forge inspect <path>:<name> bytecode` into its file, and run the script's `--check`, which refuses the files unless they still give the canonical addresses.
