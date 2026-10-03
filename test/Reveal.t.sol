// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { BaseTest } from "./Base.t.sol";
import { TwoStepOwnable } from "utility-contracts/TwoStepOwnable.sol";
import { NightfallGenesis } from "../src/NightfallGenesis.sol";
import { PublicDrop } from "seadrop/lib/SeaDropStructs.sol";

contract RevealTest is BaseTest {
    bytes32 internal secret = keccak256("the secret nobody sees until the reveal");
    bytes32 internal commitment;
    uint256 internal target;

    event EntropyCaptured(uint256 indexed blockNumber, bytes32 blockHash, bool missedTarget);
    event Revealed(bytes32 secret, bytes32 entropy, uint256 offset);
    event MintClosed(uint256 minted, uint256 targetBlock, bool soldOut);

    /// @dev A second token with the same stage but no commitment.
    function _freshToken() internal returns (NightfallGenesis fresh) {
        address[] memory allowed = new address[](1);
        allowed[0] = address(seadrop);
        fresh = new NightfallGenesis("Fresh", "FR", allowed);
        fresh.setMaxSupply(MAX_SUPPLY);
        fresh.updateCreatorPayoutAddress(address(seadrop), payout);
        fresh.updateAllowedFeeRecipient(address(seadrop), feeRecipient, true);
        fresh.updatePublicDrop(
            address(seadrop),
            PublicDrop({ mintPrice: 0, startTime: uint48(block.timestamp), endTime: uint48(block.timestamp + 7 days), maxTotalMintableByWallet: 5, feeBps: 0, restrictFeeRecipients: true })
        );
    }

    function setUp() public override {
        super.setUp();
        commitment = keccak256(abi.encodePacked(secret));
    }

    function _hashFor(uint256 n) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("block", n));
    }

    /// @dev Gives every block from `from` to `to` a known, non-zero hash. Forge only lets a
    ///      hash be set for a block at or before the current one, so roll first.
    function _seedHashes(uint256 from, uint256 to) internal {
        for (uint256 n = from; n <= to; ++n) vm.setBlockhash(n, _hashFor(n));
    }

    /// @dev Ten tokens minted, then the owner closes the mint, which sets the target.
    function _commitAndMint() internal {
        token.commitReveal(commitment);
        mintPublic(alice, 5);
        mintPublic(bob, 5);
        token.closeMint();
        target = token.revealTargetBlock();
    }

    function _commitAndClose(bytes32 c) internal {
        token.commitReveal(c);
        token.closeMint();
        target = token.revealTargetBlock();
    }

    function _expectedOffset(bytes32 s, bytes32 entropy) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(s, entropy))) % MAX_SUPPLY;
    }

    // ---------------------------------------------------------------- commit

    function test_commitOnlyBeforeTheFirstMint() public {
        token.commitReveal(commitment);
        assertEq(token.revealCommitment(), commitment);
        assertEq(token.revealTargetBlock(), 0); // no target until minting closes
        // Before anything mints the owner may still correct it.
        token.commitReveal(keccak256("other"));
        assertEq(token.revealCommitment(), keccak256("other"));
        mintPublic(alice, 1);
        vm.expectRevert(NightfallGenesis.CommitAfterMintStarted.selector);
        token.commitReveal(commitment);
    }

    function test_commitRefusesZero() public {
        vm.expectRevert(NightfallGenesis.ZeroCommitment.selector);
        token.commitReveal(bytes32(0));
    }

    function test_commitIsOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.OnlyOwner.selector);
        token.commitReveal(commitment);
    }

    function test_theFirstMintNeedsACommitment() public {
        NightfallGenesis fresh = _freshToken();
        vm.prank(alice);
        vm.expectRevert(NightfallGenesis.RevealNotCommitted.selector);
        seadrop.mintPublic(address(fresh), feeRecipient, address(0), 1);
        vm.expectRevert(NightfallGenesis.RevealNotCommitted.selector);
        fresh.closeMint();
    }

    // ---------------------------------------------------------------- closing the mint

    function test_closeMintSetsTheTargetAFixedMarginAhead() public {
        token.commitReveal(commitment);
        mintPublic(alice, 3);
        uint256 closedAt = block.number;
        vm.expectEmit(true, true, true, true);
        emit MintClosed(3, closedAt + 30, false);
        token.closeMint();
        assertTrue(token.mintClosed());
        assertEq(token.REVEAL_DELAY_BLOCKS(), 30);
        assertEq(token.revealTargetBlock(), closedAt + 30);
    }

    function test_nothingMintsAfterTheClose() public {
        _commitAndMint();
        vm.prank(carol);
        vm.expectRevert(NightfallGenesis.MintIsClosed.selector);
        seadrop.mintPublic(address(token), feeRecipient, address(0), 1);
        // Not even the owner reopening a stage.
        token.updatePublicDrop(
            address(seadrop),
            PublicDrop({ mintPrice: 0, startTime: uint48(block.timestamp), endTime: uint48(block.timestamp + 1 days), maxTotalMintableByWallet: 100, feeBps: 0, restrictFeeRecipients: true })
        );
        vm.prank(carol);
        vm.expectRevert(NightfallGenesis.MintIsClosed.selector);
        seadrop.mintPublic(address(token), feeRecipient, address(0), 1);
        assertEq(token.totalSupply(), 10);
    }

    function test_closeIsOneWayAndOwnerOnly() public {
        _commitAndMint();
        vm.expectRevert(NightfallGenesis.MintIsClosed.selector);
        token.closeMint();
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.OnlyOwner.selector);
        token.closeMint();
    }

    function test_theTargetCannotBeReachedBeforeTheClose() public {
        token.commitReveal(commitment);
        mintPublic(alice, 5);
        vm.roll(block.number + 10_000);
        vm.expectRevert(NightfallGenesis.MintStillOpen.selector);
        token.entropyCandidate();
        vm.expectRevert(NightfallGenesis.MintStillOpen.selector);
        token.captureEntropy();
    }

    function test_sellOutClosesTheMintByItself() public {
        token.commitReveal(commitment);
        mintAll();
        assertEq(token.totalSupply(), MAX_SUPPLY);
        assertTrue(token.mintClosed());
        assertEq(token.revealTargetBlock(), block.number + 30);
        vm.expectRevert(NightfallGenesis.MintIsClosed.selector);
        token.closeMint();
    }

    function test_theSupplyGuardStillHoldsAfterTheClose() public {
        _commitAndMint();
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.SupplyFixedAfterMintStarted.selector, MAX_SUPPLY));
        token.setMaxSupply(10);
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.SupplyFixedAfterMintStarted.selector, MAX_SUPPLY));
        token.setMaxSupply(556);
        assertEq(token.maxSupply(), MAX_SUPPLY);
    }

    function test_revealWorksWithFewerThanMaxSupplyMinted() public {
        _commitAndMint(); // 10 of 555
        vm.roll(target + 1);
        _seedHashes(target, target);
        token.captureEntropy();
        token.reveal(secret);
        uint256 offset = token.revealOffset();
        assertLt(offset, MAX_SUPPLY);
        // The ten minted tokens take ten distinct rows of the full table; the other 545 rows
        // simply never appear.
        for (uint256 id = 1; id <= 10; ++id) {
            assertEq(renderer.rowOf(id, offset), (id + offset) % MAX_SUPPLY);
            assertEq(token.tokenURI(id), renderer.tokenURI(id, true, offset, 0, ""));
        }
        vm.expectRevert();
        token.tokenURI(11);
    }

    // ---------------------------------------------------------------- capture

    function test_captureNeedsTheMintClosed() public {
        vm.expectRevert(NightfallGenesis.MintStillOpen.selector);
        token.captureEntropy();
        vm.expectRevert(NightfallGenesis.MintStillOpen.selector);
        token.entropyCandidate();
    }

    function test_captureWaitsForTheTargetToPass() public {
        _commitAndMint();
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.TargetBlockNotReached.selector, target, block.number));
        token.captureEntropy();
        vm.roll(target); // the target block itself: its hash is not known yet
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.TargetBlockNotReached.selector, target, target));
        token.captureEntropy();
    }

    function test_anyoneCapturesTheTargetHash() public {
        _commitAndMint();
        vm.roll(target + 1);
        _seedHashes(target, target);
        assertEq(token.entropyCandidate(), target);
        vm.expectEmit(true, true, true, true);
        emit EntropyCaptured(target, _hashFor(target), false);
        vm.prank(carol);
        token.captureEntropy();
        assertEq(token.revealEntropy(), _hashFor(target));
        assertEq(token.revealEntropyBlock(), target);
    }

    function test_captureHappensOnce() public {
        _commitAndMint();
        vm.roll(target + 1);
        _seedHashes(target, target);
        token.captureEntropy();
        vm.roll(target + 100);
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.EntropyAlreadyCaptured.selector, target));
        token.captureEntropy();
    }

    function test_theTargetHashIsReadableForTheWholeStride() public {
        _commitAndMint();
        vm.roll(target + 256); // the last block where blockhash(target) still works
        _seedHashes(target, target);
        assertEq(token.entropyCandidate(), target);
        token.captureEntropy();
        assertEq(token.revealEntropyBlock(), target);
    }

    function test_aMissedTargetMovesToTheNextStride() public {
        _commitAndMint();
        vm.roll(target + 257); // the target's hash has just aged out
        assertEq(token.entropyCandidate(), target + 256);
        vm.roll(target + 300);
        assertEq(token.entropyCandidate(), target + 256);
        vm.roll(target + 512);
        assertEq(token.entropyCandidate(), target + 256);
        vm.roll(target + 513);
        assertEq(token.entropyCandidate(), target + 512);
        _seedHashes(target + 512, target + 512);
        vm.expectEmit(true, true, true, true);
        emit EntropyCaptured(target + 512, _hashFor(target + 512), true);
        token.captureEntropy();
        assertEq(token.revealEntropyBlock(), target + 512);
    }

    function test_captureRefusesAMissingBlockHash() public {
        _commitAndMint();
        vm.roll(target + 1);
        vm.setBlockhash(target, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.BlockHashUnavailable.selector, target));
        token.captureEntropy();
    }

    // ---------------------------------------------------------------- reveal

    function test_revealNeedsCapturedEntropy() public {
        _commitAndMint();
        vm.expectRevert(NightfallGenesis.EntropyNotCaptured.selector);
        token.reveal(secret);
        vm.roll(target + 1);
        vm.expectRevert(NightfallGenesis.EntropyNotCaptured.selector);
        token.reveal(secret);
    }

    function test_revealFlow() public {
        _commitAndMint();
        string memory before = token.tokenURI(1);
        vm.roll(target + 1);
        _seedHashes(target, target);
        token.captureEntropy();
        bytes32 entropy = token.revealEntropy();
        uint256 expected = _expectedOffset(secret, entropy);

        vm.expectEmit(true, true, true, true);
        emit Revealed(secret, entropy, expected);
        token.reveal(secret);

        assertTrue(token.revealed());
        assertEq(token.revealOffset(), expected);
        assertLt(expected, MAX_SUPPLY);
        assertTrue(keccak256(bytes(token.tokenURI(1))) != keccak256(bytes(before)));
        assertEq(token.tokenURI(1), renderer.tokenURI(1, true, expected, 0, ""));
        assertEq(renderer.rowOf(1, expected), (1 + expected) % MAX_SUPPLY);
    }

    function test_revealHasNoDeadline() public {
        _commitAndMint();
        vm.roll(target + 1);
        _seedHashes(target, target);
        token.captureEntropy();
        vm.roll(target + 1_000_000);
        vm.warp(block.timestamp + 365 days);
        token.reveal(secret);
        assertTrue(token.revealed());
    }

    function test_anyoneWithTheSecretReveals() public {
        _commitAndMint();
        vm.roll(target + 1);
        _seedHashes(target, target);
        token.captureEntropy();
        vm.prank(carol);
        token.reveal(secret);
        assertTrue(token.revealed());
    }

    function test_revealRefusesTheWrongSecret() public {
        _commitAndMint();
        vm.roll(target + 1);
        _seedHashes(target, target);
        token.captureEntropy();
        vm.expectRevert(NightfallGenesis.WrongSecret.selector);
        token.reveal(keccak256("wrong"));
        assertFalse(token.revealed());
    }

    function test_revealHappensOnce() public {
        _commitAndMint();
        vm.roll(target + 1);
        _seedHashes(target, target);
        token.captureEntropy();
        token.reveal(secret);
        vm.expectRevert(NightfallGenesis.AlreadyRevealed.selector);
        token.reveal(secret);
        vm.expectRevert(NightfallGenesis.AlreadyRevealed.selector);
        token.captureEntropy();
        vm.expectRevert(NightfallGenesis.CommitAfterMintStarted.selector);
        token.commitReveal(commitment);
    }

    function test_theOutcomeIsFixedAtCapture() public {
        _commitAndMint();
        vm.roll(target + 1);
        _seedHashes(target, target);
        token.captureEntropy();
        uint256 fixedOffset = _expectedOffset(secret, token.revealEntropy());
        // Nothing the owner does between capture and reveal changes the result.
        vm.roll(target + 5000);
        token.setRenderer(address(renderer));
        token.setMaxLockSeconds(1 hours);
        token.reveal(secret);
        assertEq(token.revealOffset(), fixedOffset);
    }

    function test_everyTokenRendersADistinctRowAfterReveal() public {
        _commitAndMint();
        vm.roll(target + 1);
        _seedHashes(target, target);
        token.captureEntropy();
        token.reveal(secret);
        uint256 offset = token.revealOffset();
        for (uint256 id = 1; id <= 10; ++id) {
            uint256 r = renderer.rowOf(id, offset);
            assertLt(r, MAX_SUPPLY);
            for (uint256 other = 1; other < id; ++other) {
                assertTrue(renderer.rowOf(other, offset) != r);
            }
        }
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_offsetIsAlwaysInsideTheTable(bytes32 s, bytes32 h) public {
        vm.assume(h != bytes32(0));
        _commitAndClose(keccak256(abi.encodePacked(s)));
        vm.roll(target + 1);
        vm.setBlockhash(target, h);
        token.captureEntropy();
        token.reveal(s);
        assertLt(token.revealOffset(), MAX_SUPPLY);
        assertEq(token.revealOffset(), _expectedOffset(s, h));
    }

    function testFuzz_onlyTheCommittedSecretReveals(bytes32 s, bytes32 wrong) public {
        vm.assume(s != wrong);
        _commitAndClose(keccak256(abi.encodePacked(s)));
        vm.roll(target + 1);
        vm.setBlockhash(target, keccak256("h"));
        token.captureEntropy();
        vm.expectRevert(NightfallGenesis.WrongSecret.selector);
        token.reveal(wrong);
    }

    /// @dev At any block after the target there is exactly one candidate, it is a whole number of
    ///      strides past the target, and its hash is still readable.
    function testFuzz_exactlyOneReadableCandidateAtAnyTime(uint256 delta) public {
        delta = bound(delta, 1, 100_000);
        _commitAndClose(commitment);
        vm.roll(target + delta);
        uint256 c = token.entropyCandidate();
        assertGe(c, target);
        assertLt(c, block.number);
        assertEq((c - target) % 256, 0);
        assertLe(block.number - c, 256); // blockhash(c) is still available
        // The next stride is not readable yet and the previous one has aged out.
        assertGe(c + 256, block.number);
        if (c >= 256) assertGt(block.number - (c - 256), 256);
    }

    function testFuzz_captureStoresTheCandidateHash(uint256 delta, bytes32 h) public {
        delta = bound(delta, 1, 100_000);
        vm.assume(h != bytes32(0));
        _commitAndClose(commitment);
        vm.roll(target + delta);
        uint256 c = token.entropyCandidate();
        vm.setBlockhash(c, h);
        token.captureEntropy();
        assertEq(token.revealEntropy(), h);
        assertEq(token.revealEntropyBlock(), c);
    }
}
