// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { BaseTest } from "./Base.t.sol";
import { TwoStepOwnable } from "utility-contracts/TwoStepOwnable.sol";
import { INonFungibleSeaDropToken } from "seadrop/interfaces/INonFungibleSeaDropToken.sol";
import { IERC721A } from "ERC721A/IERC721A.sol";
import { NightfallGenesis } from "../src/NightfallGenesis.sol";

contract LockTest is BaseTest {
    uint256[] internal ids;
    uint64[] internal untils;

    function setUp() public override {
        super.setUp();
        mintPublic(alice, 3);
    }

    function _lock(uint256 id, uint64 until) internal {
        delete ids;
        delete untils;
        ids.push(id);
        untils.push(until);
        vm.prank(operator);
        token.lockUntil(ids, untils);
    }

    function test_operatorLocksSeveralInOneCall() public {
        uint64 now_ = uint64(block.timestamp);
        delete ids;
        delete untils;
        ids.push(1);
        ids.push(2);
        ids.push(3);
        untils.push(now_ + 1 hours);
        untils.push(now_ + 2 hours);
        untils.push(now_ + 3 hours);
        vm.prank(operator);
        token.lockUntil(ids, untils);
        assertEq(token.lockedUntil(1), now_ + 1 hours);
        assertEq(token.lockedUntil(2), now_ + 2 hours);
        assertEq(token.lockedUntil(3), now_ + 3 hours);
        assertTrue(token.isLocked(1) && token.isLocked(2) && token.isLocked(3));
    }

    function test_lockedTokenCannotMove() public {
        uint64 until = uint64(block.timestamp + 6 hours + 15 minutes);
        _lock(1, until);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.TokenLocked.selector, 1, until));
        token.transferFrom(alice, bob, 1);
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.TokenLocked.selector, 1, until));
        token.safeTransferFrom(alice, bob, 1);
        // An unlocked sibling moves.
        token.transferFrom(alice, bob, 2);
        vm.stopPrank();
        assertEq(token.ownerOf(1), alice);
        assertEq(token.ownerOf(2), bob);
    }

    function test_lockExpiresOnItsOwn() public {
        uint64 until = uint64(block.timestamp + 1 hours);
        _lock(1, until);
        vm.warp(until - 1);
        assertTrue(token.isLocked(1));
        vm.warp(until);
        assertFalse(token.isLocked(1));
        vm.prank(alice);
        token.transferFrom(alice, bob, 1);
        assertEq(token.ownerOf(1), bob);
    }

    function test_operatorLiftsALockEarly() public {
        _lock(1, uint64(block.timestamp + 12 hours));
        assertTrue(token.isLocked(1));
        _lock(1, uint64(block.timestamp));
        assertFalse(token.isLocked(1));
        vm.prank(alice);
        token.transferFrom(alice, bob, 1);
    }

    function test_operatorExtendsALock() public {
        uint64 runEnd = uint64(block.timestamp + 6 hours);
        _lock(1, runEnd);
        vm.warp(runEnd - 1);
        // Busted at resolve: the lock now covers the 12 hour jail plus the buffer.
        uint64 jailEnd = uint64(block.timestamp + 12 hours + 15 minutes);
        _lock(1, jailEnd);
        assertEq(token.lockedUntil(1), jailEnd);
        vm.warp(runEnd + 1);
        assertTrue(token.isLocked(1));
    }

    function test_ceilingIsMeasuredFromTheCall() public {
        uint64 latest = uint64(block.timestamp) + MAX_LOCK;
        _lock(1, latest);
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.LockTooLong.selector, 2, latest + 1, latest));
        _lock(2, latest + 1);
        // A 12 hour heist that ends Burned: 24 hours of jail plus the buffer, set at resolve,
        // still fits under 26 hours measured from then.
        vm.warp(block.timestamp + 12 hours);
        _lock(1, uint64(block.timestamp + 24 hours + 15 minutes));
    }

    function test_onlyTheOperatorLocks() public {
        delete ids;
        delete untils;
        ids.push(1);
        untils.push(uint64(block.timestamp + 1 hours));
        vm.expectRevert(NightfallGenesis.NotOperator.selector); // the owner is not the operator
        token.lockUntil(ids, untils);
        vm.prank(alice);
        vm.expectRevert(NightfallGenesis.NotOperator.selector);
        token.lockUntil(ids, untils);
    }

    function test_arraysMustMatch() public {
        delete ids;
        delete untils;
        ids.push(1);
        ids.push(2);
        untils.push(uint64(block.timestamp + 1 hours));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.LockArraysMismatch.selector, 2, 1));
        token.lockUntil(ids, untils);
    }

    function test_cannotLockATokenThatDoesNotExist() public {
        vm.expectRevert(IERC721A.URIQueryForNonexistentToken.selector);
        _lock(4, uint64(block.timestamp + 1 hours));
    }

    function test_lockedTokenCannotBeBurned() public {
        uint64 until = uint64(block.timestamp + 1 hours);
        _lock(1, until);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.TokenLocked.selector, 1, until));
        token.burn(1);
    }

    function test_lockBlocksAnApprovedOperatorToo() public {
        uint64 until = uint64(block.timestamp + 1 hours);
        vm.prank(alice);
        token.setApprovalForAll(bob, true);
        _lock(1, until);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.TokenLocked.selector, 1, until));
        token.transferFrom(alice, carol, 1);
    }

    function test_lockDoesNotBlockMinting() public {
        _lock(1, uint64(block.timestamp + 1 hours));
        mintPublic(bob, 5);
        assertEq(token.totalSupply(), 8);
    }

    function test_theLockFollowsTheTokenNotTheOwner() public {
        // Unlocked, transferred, then locked by the new owner's run. The lock is on the token id.
        vm.prank(alice);
        token.transferFrom(alice, bob, 1);
        uint64 until = uint64(block.timestamp + 1 hours);
        _lock(1, until);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.TokenLocked.selector, 1, until));
        token.transferFrom(bob, carol, 1);
    }

    function test_operatorCanDoNothingElse() public {
        vm.startPrank(operator);
        vm.expectRevert(TwoStepOwnable.OnlyOwner.selector);
        token.setMaxSupply(1000);
        vm.expectRevert(TwoStepOwnable.OnlyOwner.selector);
        token.setOperator(operator);
        vm.expectRevert(TwoStepOwnable.OnlyOwner.selector);
        token.setMaxLockSeconds(1);
        vm.expectRevert(TwoStepOwnable.OnlyOwner.selector);
        token.setRenderer(address(0));
        vm.expectRevert(TwoStepOwnable.OnlyOwner.selector);
        token.setTransferValidator(address(1));
        vm.expectRevert(TwoStepOwnable.OnlyOwner.selector);
        token.transferOwnership(operator);
        vm.expectRevert(INonFungibleSeaDropToken.OnlyAllowedSeaDrop.selector);
        token.mintSeaDrop(operator, 1);
        vm.expectRevert(IERC721A.TransferCallerNotOwnerNorApproved.selector);
        token.transferFrom(alice, operator, 1);
        vm.expectRevert(); // OnlyOwner, through _onlyOwnerOrSelf
        token.setRoyaltyInfo(ISeaDropTokenContractMetadata.RoyaltyInfo(operator, 10_000));
        vm.expectRevert();
        token.updateCreatorPayoutAddress(address(seadrop), operator);
        vm.stopPrank();
    }

    function test_ownerReplacesOrRemovesTheOperator() public {
        address next = makeAddr("nextOperator");
        token.setOperator(next);
        delete ids;
        delete untils;
        ids.push(1);
        untils.push(uint64(block.timestamp + 1 hours));
        vm.prank(operator);
        vm.expectRevert(NightfallGenesis.NotOperator.selector);
        token.lockUntil(ids, untils);
        vm.prank(next);
        token.lockUntil(ids, untils);
        assertTrue(token.isLocked(1));
        token.setOperator(address(0));
        vm.prank(next);
        vm.expectRevert(NightfallGenesis.NotOperator.selector);
        token.lockUntil(ids, untils);
        // Existing locks still expire on their own.
        vm.warp(block.timestamp + 1 hours);
        assertFalse(token.isLocked(1));
    }

    function test_maxLockMustBePositive() public {
        vm.expectRevert(NightfallGenesis.ZeroMaxLock.selector);
        token.setMaxLockSeconds(0);
        token.setMaxLockSeconds(1);
        assertEq(token.maxLockSeconds(), 1);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_anyLockWithinTheCeilingIsAccepted(uint64 delta) public {
        delta = uint64(bound(delta, 0, MAX_LOCK));
        uint64 until = uint64(block.timestamp) + delta;
        _lock(1, until);
        assertEq(token.lockedUntil(1), until);
        assertEq(token.isLocked(1), delta > 0);
    }

    function testFuzz_anyLockPastTheCeilingIsRefused(uint64 delta) public {
        delta = uint64(bound(delta, MAX_LOCK + 1, type(uint64).max - uint64(block.timestamp)));
        uint64 until = uint64(block.timestamp) + delta;
        uint64 latest = uint64(block.timestamp) + MAX_LOCK;
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.LockTooLong.selector, 1, until, latest));
        _lock(1, until);
    }

    function testFuzz_transferIsBlockedExactlyWhileLocked(uint64 delta, uint64 wait) public {
        delta = uint64(bound(delta, 1, MAX_LOCK));
        wait = uint64(bound(wait, 0, MAX_LOCK + 1 hours));
        uint64 until = uint64(block.timestamp) + delta;
        _lock(1, until);
        vm.warp(block.timestamp + wait);
        vm.prank(alice);
        if (block.timestamp < until) {
            vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.TokenLocked.selector, 1, until));
            token.transferFrom(alice, bob, 1);
            assertEq(token.ownerOf(1), alice);
        } else {
            token.transferFrom(alice, bob, 1);
            assertEq(token.ownerOf(1), bob);
        }
    }

    function testFuzz_onlyTheOperatorAddressLocks(address caller) public {
        vm.assume(caller != operator);
        delete ids;
        delete untils;
        ids.push(1);
        untils.push(uint64(block.timestamp + 1));
        vm.prank(caller);
        vm.expectRevert(NightfallGenesis.NotOperator.selector);
        token.lockUntil(ids, untils);
    }

    function testFuzz_bulkLockSetsEachTokenItsOwnExpiry(uint64 a, uint64 b, uint64 c) public {
        a = uint64(bound(a, 0, MAX_LOCK));
        b = uint64(bound(b, 0, MAX_LOCK));
        c = uint64(bound(c, 0, MAX_LOCK));
        uint64 now_ = uint64(block.timestamp);
        delete ids;
        delete untils;
        ids.push(1);
        ids.push(2);
        ids.push(3);
        untils.push(now_ + a);
        untils.push(now_ + b);
        untils.push(now_ + c);
        vm.prank(operator);
        token.lockUntil(ids, untils);
        assertEq(token.lockedUntil(1), now_ + a);
        assertEq(token.lockedUntil(2), now_ + b);
        assertEq(token.lockedUntil(3), now_ + c);
    }
}

import { ISeaDropTokenContractMetadata } from "seadrop/interfaces/ISeaDropTokenContractMetadata.sol";
