# SeaDrop, vendored

`src/` is `ProjectOpenSea/seadrop` at commit `757590f11babfd81f4608f736e79e388469377f2`, the same commit the
submodule pinned, copied in as files so that one change can be carried and audited inside this repository.
Only `src/` and `LICENSE` are kept; SeaDrop's tests, scripts and tooling are not needed to build the token.

The one change against upstream, in its own commit right after the copy:

- `src/ERC721ContractMetadata.sol`: `setMaxSupply` is declared `virtual`, so `NightfallGenesis` can override
  it and refuse any change to the supply once minting has started. Behaviour, ABI and events are untouched.

To audit: `git log --oneline -- contracts/lib/seadrop` shows the copy commit and the patch commit;
`git diff <copy commit> <patch commit> -- contracts/lib/seadrop` is the whole difference against upstream.
