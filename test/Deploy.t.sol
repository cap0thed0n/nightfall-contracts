// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { SeaDrop } from "seadrop/SeaDrop.sol";
import { PublicDrop } from "seadrop/lib/SeaDropStructs.sol";
import { DeployTestnet } from "../script/DeployTestnet.s.sol";
import { NightfallGenesis } from "../src/NightfallGenesis.sol";
import { NightfallRenderer } from "../src/NightfallRenderer.sol";
import { PlaceholderArt } from "../src/art/PlaceholderArt.sol";
import { ArtFile } from "../script/ArtFile.sol";
import { DenylistValidator } from "./mocks/Validators.sol";

/// @notice Runs the deploy script's logic against a local SeaDrop with the committed config,
///         so the file the deploy runs from is known to produce a working collection.
contract DeployTest is Test {
    DeployTestnet internal script;
    SeaDrop internal seadrop;
    DeployTestnet.Config internal cfg;

    function setUp() public {
        vm.warp(1_800_000_000);
        script = new DeployTestnet();
        seadrop = new SeaDrop();
        cfg = script.load(script.CONFIG_PATH());
        // The committed config names the real art, which lives only on the deploying machine (git-ignored).
        // Anywhere else the committed fixture stands in, so the deploy's logic is tested everywhere.
        if (!vm.isFile(cfg.artFile)) cfg.artFile = "deploy/art/fixture-genesis.json";
        cfg.seaDrop = address(seadrop);
        cfg.royaltyReceiver = makeAddr("royalty");
        cfg.creatorPayout = makeAddr("payout");
        cfg.feeRecipient = makeAddr("fee");
        cfg.operator = makeAddr("operator");
        // The committed file leaves the commitment for the reveal sheet; minting needs one.
        cfg.revealCommitment = keccak256(abi.encodePacked(bytes32("deploy test secret")));
    }

    function test_committedConfigDeploysAndMints() public {
        (NightfallGenesis token, NightfallRenderer renderer) = script.deployAll(cfg);

        assertEq(token.name(), "Nightfall Genesis");
        assertEq(token.symbol(), "NFG");
        assertEq(token.maxSupply(), 555);
        assertEq(token.maxLockSeconds(), 26 hours);
        assertEq(token.operator(), cfg.operator);
        assertEq(address(token.renderer()), address(renderer));
        // The committed config stores the pre-reveal GIF, byte for byte.
        assertEq(keccak256(renderer.preRevealImage()), keccak256(vm.readFileBinary("deploy/art/prereveal/pre-reveal160x.gif")));
        assertGt(renderer.preRevealImage().length, 0);
        assertEq(token.provenanceHash(), renderer.tableHash());
        // In a test the script contract is the deployer; under `forge script --broadcast` the
        // deployer key is, and it owns both contracts.
        assertEq(token.owner(), address(script));
        assertEq(renderer.owner(), address(script));
        assertEq(renderer.rowCount(), 555);
        assertEq(renderer.categoryCount(), 7);
        assertEq(renderer.tierColours().length, 3);
        (address receiver, uint256 amount) = token.royaltyInfo(1, 10_000);
        assertEq(receiver, cfg.royaltyReceiver);
        assertEq(amount, 650);

        PublicDrop memory drop = seadrop.getPublicDrop(address(token));
        assertEq(drop.maxTotalMintableByWallet, 5);
        // The rehearsal config: a tiny price with the real 10% OpenSea fee and 6.5% royalty.
        assertEq(drop.mintPrice, 0.0001 ether);
        assertEq(drop.feeBps, 1000);
        assertEq(seadrop.getCreatorPayoutAddress(address(token)), cfg.creatorPayout);

        // A paid mint: SeaDrop pays the fee and the creator inside the mint transaction.
        address minter = makeAddr("minter");
        vm.deal(minter, 1 ether);
        uint256 cost = 5 * uint256(drop.mintPrice);
        vm.prank(minter);
        seadrop.mintPublic{ value: cost }(address(token), cfg.feeRecipient, address(0), 5);
        assertEq(token.balanceOf(minter), 5);
        assertEq(cfg.feeRecipient.balance, cost / 10);
        assertEq(cfg.creatorPayout.balance, cost - cost / 10);
        assertTrue(bytes(token.tokenURI(1)).length > 0);
        // The supply rule with the patched SeaDrop compiled in: no change once minting started,
        // and the next paid mint through SeaDrop still works.
        vm.prank(address(script)); // the script contract owns the token in a test
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.SupplyFixedAfterMintStarted.selector, uint256(555)));
        token.setMaxSupply(556);
        address second = makeAddr("second");
        vm.deal(second, 1 ether);
        vm.prank(second);
        seadrop.mintPublic{ value: drop.mintPrice }(address(token), cfg.feeRecipient, address(0), 1);
        assertEq(token.totalSupply(), 6);
        // Underpaying fails.
        vm.deal(makeAddr("cheap"), 1 ether);
        vm.prank(makeAddr("cheap"));
        vm.expectRevert();
        seadrop.mintPublic{ value: drop.mintPrice - 1 }(address(token), cfg.feeRecipient, address(0), 1);
    }

    function test_configFlagsApply() public {
        DenylistValidator validator = new DenylistValidator();
        cfg.transferValidator = address(validator);
        cfg.revealCommitment = keccak256(abi.encodePacked(bytes32("s")));
        cfg.contractURI = "ipfs://contract";
        cfg.dropURI = "ipfs://drop";
        (NightfallGenesis token,) = script.deployAll(cfg);
        assertEq(token.getTransferValidator(), address(validator));
        assertEq(token.revealCommitment(), cfg.revealCommitment);
        assertEq(token.revealTargetBlock(), 0); // set only when minting closes
        assertEq(token.contractURI(), "ipfs://contract");
    }

    function test_missingAddressesAreRefused() public {
        cfg.royaltyReceiver = address(0);
        vm.expectRevert("royaltyReceiver required");
        script.deployAll(cfg);
    }

    function test_tableIsDeterministicFromTheSeed() public {
        (, NightfallRenderer a) = script.deployAll(cfg);
        (, NightfallRenderer b) = script.deployAll(cfg);
        assertEq(a.tableHash(), b.tableHash());
        // With an art file the table is the file's, committed by its provenance hash; without one
        // it is the placeholder table built from the config's seed.
        if (bytes(cfg.artFile).length != 0) assertEq(a.tableHash(), ArtFile.load(cfg.artFile).provenanceHash);
        else assertEq(a.tableHash(), keccak256(PlaceholderArt.table(555, cfg.tableSeed)));
    }
}
