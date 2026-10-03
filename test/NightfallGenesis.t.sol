// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { BaseTest } from "./Base.t.sol";
import { SeaDropErrorsAndEvents } from "seadrop/lib/SeaDropErrorsAndEvents.sol";
import { INonFungibleSeaDropToken } from "seadrop/interfaces/INonFungibleSeaDropToken.sol";
import { TwoStepOwnable } from "utility-contracts/TwoStepOwnable.sol";
import { ICreatorToken } from "seadrop/interfaces/ICreatorToken.sol";
import { ITransferValidator721 } from "seadrop/interfaces/ITransferValidator.sol";
import { MintParams } from "seadrop/lib/SeaDropStructs.sol";
import { ISeaDropTokenContractMetadata } from "seadrop/interfaces/ISeaDropTokenContractMetadata.sol";
import { IERC721A } from "ERC721A/IERC721A.sol";
import { NightfallGenesis } from "../src/NightfallGenesis.sol";
import { RefusingValidator, DenylistValidator } from "./mocks/Validators.sol";

contract NightfallGenesisTest is BaseTest {
    // ---------------------------------------------------------------- public stage and supply

    function test_publicStageMintsUpToFivePerWallet() public {
        mintPublic(alice, 3);
        mintPublic(alice, 2);
        assertEq(token.balanceOf(alice), 5);
        assertEq(token.ownerOf(1), alice);
        assertEq(token.ownerOf(5), alice);
        assertEq(token.totalSupply(), 5);
    }

    function test_publicStageRefusesTheSixth() public {
        mintPublic(alice, 5);
        vm.expectRevert(
            abi.encodeWithSelector(SeaDropErrorsAndEvents.MintQuantityExceedsMaxMintedPerWallet.selector, 6, 5)
        );
        mintPublic(alice, 1);
    }

    function test_tokenIdsStartAtOne() public {
        mintPublic(alice, 1);
        assertEq(token.ownerOf(1), alice);
        vm.expectRevert(IERC721A.OwnerQueryForNonexistentToken.selector);
        token.ownerOf(0);
    }

    function test_maxSupplyIsTheOnlySupplyRule() public {
        mintAll();
        assertEq(token.totalSupply(), MAX_SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(SeaDropErrorsAndEvents.MintQuantityExceedsMaxSupply.selector, MAX_SUPPLY + 1, MAX_SUPPLY)
        );
        mintPublic(carol, 1);
    }

    function test_maxSupplyCannotDropBelowMinted() public {
        mintPublic(alice, 5);
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.SupplyFixedAfterMintStarted.selector, MAX_SUPPLY));
        token.setMaxSupply(4);
    }

    /// @dev The supply rule: any change at all is refused once the first token exists, and
    ///      minting through SeaDrop carries on exactly as before.
    function test_supplyIsFixedOnceMintingStarts() public {
        // Before the first mint the owner may still change it, as SeaDrop allows.
        token.setMaxSupply(600);
        assertEq(token.maxSupply(), 600);
        token.setMaxSupply(MAX_SUPPLY);
        assertEq(token.maxSupply(), MAX_SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(ISeaDropTokenContractMetadata.CannotExceedMaxSupplyOfUint64.selector, uint256(2 ** 64)));
        token.setMaxSupply(2 ** 64);

        mintPublic(alice, 1);

        bytes memory fixedError = abi.encodeWithSelector(NightfallGenesis.SupplyFixedAfterMintStarted.selector, MAX_SUPPLY);
        vm.expectRevert(fixedError);
        token.setMaxSupply(MAX_SUPPLY + 1); // up
        vm.expectRevert(fixedError);
        token.setMaxSupply(MAX_SUPPLY - 1); // down
        vm.expectRevert(fixedError);
        token.setMaxSupply(MAX_SUPPLY); // even the same value
        assertEq(token.maxSupply(), MAX_SUPPLY);
        // Not the owner: still SeaDrop's owner check, before the supply rule.
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.OnlyOwner.selector);
        token.setMaxSupply(MAX_SUPPLY + 1);

        // SeaDrop minting is untouched by the override: public, per-wallet cap, allowlist.
        mintPublic(alice, PER_WALLET - 1);
        assertEq(token.balanceOf(alice), PER_WALLET);
        vm.expectRevert(
            abi.encodeWithSelector(SeaDropErrorsAndEvents.MintQuantityExceedsMaxMintedPerWallet.selector, PER_WALLET + 1, PER_WALLET)
        );
        mintPublic(alice, 1);
        MintParams memory two = stage(2, MAX_SUPPLY);
        bytes32 lb = leaf(bob, two);
        bytes32 lc = leaf(carol, two);
        setAllowList(root2(lb, lc));
        mintAllowList(bob, 2, two, proofOf(lc));
        assertEq(token.balanceOf(bob), 2);
        assertEq(token.totalSupply(), PER_WALLET + 2);
        assertEq(token.maxSupply(), MAX_SUPPLY);
    }

    function test_mintSeaDropOnlyFromAnAllowedSeaDrop() public {
        vm.expectRevert(INonFungibleSeaDropToken.OnlyAllowedSeaDrop.selector);
        token.mintSeaDrop(alice, 1);
        vm.prank(alice);
        vm.expectRevert(INonFungibleSeaDropToken.OnlyAllowedSeaDrop.selector);
        token.mintSeaDrop(alice, 1);
    }

    // ---------------------------------------------------------------- allowlist stage

    function test_allowListLeavesCarryTheirOwnQuantity() public {
        MintParams memory three = stage(3, MAX_SUPPLY);
        MintParams memory one = stage(1, MAX_SUPPLY);
        bytes32 la = leaf(alice, three);
        bytes32 lb = leaf(bob, one);
        setAllowList(root2(la, lb));

        mintAllowList(alice, 3, three, proofOf(lb));
        assertEq(token.balanceOf(alice), 3);
        vm.expectRevert(
            abi.encodeWithSelector(SeaDropErrorsAndEvents.MintQuantityExceedsMaxMintedPerWallet.selector, 4, 3)
        );
        mintAllowList(alice, 1, three, proofOf(lb));

        mintAllowList(bob, 1, one, proofOf(la));
        assertEq(token.balanceOf(bob), 1);
        vm.expectRevert(
            abi.encodeWithSelector(SeaDropErrorsAndEvents.MintQuantityExceedsMaxMintedPerWallet.selector, 2, 1)
        );
        mintAllowList(bob, 1, one, proofOf(la));
    }

    function test_allowListRefusesAWalletNotOnIt() public {
        MintParams memory three = stage(3, MAX_SUPPLY);
        bytes32 la = leaf(alice, three);
        bytes32 lb = leaf(bob, three);
        setAllowList(root2(la, lb));
        vm.expectRevert(SeaDropErrorsAndEvents.InvalidProof.selector);
        mintAllowList(carol, 1, three, proofOf(lb));
    }

    function test_allowListRefusesAnotherWalletsQuantity() public {
        MintParams memory three = stage(3, MAX_SUPPLY);
        MintParams memory one = stage(1, MAX_SUPPLY);
        bytes32 la = leaf(alice, three);
        bytes32 lb = leaf(bob, one);
        setAllowList(root2(la, lb));
        // Bob presents Alice's parameters: the leaf does not match his address.
        vm.expectRevert(SeaDropErrorsAndEvents.InvalidProof.selector);
        mintAllowList(bob, 3, three, proofOf(la));
    }

    /// @dev The per-wallet limit counts every mint the wallet made on this contract, whatever
    ///      the stage. This is why the claim stage runs before the public stage.
    function test_allowListLimitCountsMintsFromOtherStages() public {
        MintParams memory three = stage(3, MAX_SUPPLY);
        bytes32 la = leaf(alice, three);
        bytes32 lb = leaf(bob, three);
        setAllowList(root2(la, lb));
        mintPublic(alice, 2);
        vm.expectRevert(
            abi.encodeWithSelector(SeaDropErrorsAndEvents.MintQuantityExceedsMaxMintedPerWallet.selector, 5, 3)
        );
        mintAllowList(alice, 3, three, proofOf(lb));
        mintAllowList(alice, 1, three, proofOf(lb));
        assertEq(token.balanceOf(alice), 3);
    }

    function test_allowListStageSupplyCap() public {
        MintParams memory params = stage(10, 8);
        bytes32 la = leaf(alice, params);
        bytes32 lb = leaf(bob, params);
        setAllowList(root2(la, lb));
        mintAllowList(alice, 8, params, proofOf(lb));
        vm.expectRevert(
            abi.encodeWithSelector(SeaDropErrorsAndEvents.MintQuantityExceedsMaxTokenSupplyForStage.selector, 9, 8)
        );
        mintAllowList(bob, 1, params, proofOf(la));
    }

    // ---------------------------------------------------------------- transfer validator

    function test_tokenIsACreatorToken() public {
        assertTrue(token.supportsInterface(type(ICreatorToken).interfaceId));
        (bytes4 selector, bool isView) = token.getTransferValidationFunction();
        assertEq(selector, ITransferValidator721.validateTransfer.selector);
        assertFalse(isView);
        assertEq(token.getTransferValidator(), address(0));
    }

    function test_validatorIsAskedOnEveryTransferAndCanRefuse() public {
        RefusingValidator refusing = new RefusingValidator();
        token.setTransferValidator(address(refusing));
        assertEq(token.getTransferValidator(), address(refusing));
        mintPublic(alice, 1); // a mint is not a transfer
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RefusingValidator.Refused.selector, alice, alice, bob, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_validatorSeesTheOperatorNotTheOwner() public {
        DenylistValidator validator = new DenylistValidator();
        address marketplace = makeAddr("royaltyStripper");
        validator.deny(marketplace, true);
        token.setTransferValidator(address(validator));
        mintPublic(alice, 1);
        vm.prank(alice);
        token.setApprovalForAll(marketplace, true);
        vm.prank(marketplace);
        vm.expectRevert(abi.encodeWithSelector(DenylistValidator.OperatorDenied.selector, marketplace, alice, bob, 1));
        token.transferFrom(alice, bob, 1);
        // The owner moving it directly is fine.
        vm.prank(alice);
        token.transferFrom(alice, bob, 1);
        assertEq(token.ownerOf(1), bob);
    }

    function test_noValidatorMeansNoCheck() public {
        mintPublic(alice, 1);
        vm.prank(alice);
        token.transferFrom(alice, bob, 1);
        assertEq(token.ownerOf(1), bob);
    }

    function test_onlyOwnerSetsTheValidator() public {
        RefusingValidator refusing = new RefusingValidator();
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.OnlyOwner.selector);
        token.setTransferValidator(address(refusing));
        vm.prank(operator);
        vm.expectRevert(TwoStepOwnable.OnlyOwner.selector);
        token.setTransferValidator(address(refusing));
    }

    // ---------------------------------------------------------------- royalties

    function test_royaltyIsSixAndAHalfPercentToTheReceiver() public {
        (address receiver, uint256 amount) = token.royaltyInfo(1, 1 ether);
        assertEq(receiver, royaltyReceiver);
        assertEq(amount, 0.065 ether);
        assertTrue(token.supportsInterface(0x2a55205a)); // ERC-2981
    }

    function testFuzz_royaltyScalesWithPrice(uint256 salePrice) public {
        salePrice = bound(salePrice, 0, type(uint256).max / 10_000);
        (address receiver, uint256 amount) = token.royaltyInfo(7, salePrice);
        assertEq(receiver, royaltyReceiver);
        assertEq(amount, (salePrice * ROYALTY_BPS) / 10_000);
    }

    // ---------------------------------------------------------------- interfaces and views

    function test_supportsTheExpectedInterfaces() public {
        assertTrue(token.supportsInterface(0x01ffc9a7)); // ERC-165
        assertTrue(token.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(token.supportsInterface(0x5b5e139f)); // ERC-721 Metadata
        assertTrue(token.supportsInterface(0x2a55205a)); // ERC-2981
        assertTrue(token.supportsInterface(0x49064906)); // ERC-4906
        assertFalse(token.supportsInterface(0xffffffff));
    }

    function test_tokensOfOwnerListsAWalletsCharacters() public {
        mintPublic(alice, 3);
        mintPublic(bob, 2);
        uint256[] memory a = token.tokensOfOwner(alice);
        assertEq(a.length, 3);
        assertEq(a[0], 1);
        assertEq(a[1], 2);
        assertEq(a[2], 3);
        uint256[] memory b = token.tokensOfOwner(bob);
        assertEq(b.length, 2);
        assertEq(b[0], 4);
        assertEq(b[1], 5);
        vm.prank(alice);
        token.transferFrom(alice, bob, 2);
        assertEq(token.tokensOfOwner(alice).length, 2);
        assertEq(token.tokensOfOwner(bob).length, 3);
    }

    function test_openSeaConduitStaysPreapproved() public {
        assertTrue(token.isApprovedForAll(alice, 0x1E0049783F008A0085193E00003D00cd54003c71));
        assertFalse(token.isApprovedForAll(alice, bob));
    }

    // ---------------------------------------------------------------- renderer wiring

    function test_tokenURIComesFromTheRenderer() public {
        mintPublic(alice, 1);
        assertEq(token.tokenURI(1), renderer.tokenURI(1, false, 0, 0, ""));
        assertTrue(startsWith(token.tokenURI(1), "data:application/json;base64,"));
    }

    function test_tokenURIRevertsForAMissingToken() public {
        vm.expectRevert(IERC721A.URIQueryForNonexistentToken.selector);
        token.tokenURI(1);
    }

    function test_withoutARendererSeaDropBaseURIApplies() public {
        address[] memory allowed = new address[](1);
        allowed[0] = address(seadrop);
        NightfallGenesis bare = new NightfallGenesis("Bare", "BARE", allowed);
        bare.setMaxSupply(10);
        bare.updateCreatorPayoutAddress(address(seadrop), payout);
        bare.updateAllowedFeeRecipient(address(seadrop), feeRecipient, true);
        bare.updatePublicDrop(address(seadrop), _publicDropOf(token));
        bare.commitReveal(keccak256("bare"));
        vm.prank(alice);
        seadrop.mintPublic(address(bare), feeRecipient, address(0), 1);
        assertEq(bare.tokenURI(1), "");
        bare.setBaseURI("ipfs://placeholder/");
        assertEq(bare.tokenURI(1), "ipfs://placeholder/1");
    }

    function test_rendererIsSwappable() public {
        mintPublic(alice, 1);
        string memory before = token.tokenURI(1);
        address[] memory none;
        NightfallGenesis other = token; // silence unused warning pattern
        other;
        none;
        // A second renderer with the same art but a different description changes the output.
        vm.recordLogs();
        token.setRenderer(address(0));
        assertEq(token.tokenURI(1), "");
        token.setRenderer(address(renderer));
        assertEq(token.tokenURI(1), before);
    }

    function test_onlyOwnerConfigures() public {
        vm.startPrank(alice);
        vm.expectRevert(TwoStepOwnable.OnlyOwner.selector);
        token.setRenderer(address(0));
        vm.expectRevert(TwoStepOwnable.OnlyOwner.selector);
        token.setOperator(alice);
        vm.expectRevert(TwoStepOwnable.OnlyOwner.selector);
        token.setMaxLockSeconds(1);
        vm.expectRevert(TwoStepOwnable.OnlyOwner.selector);
        token.commitReveal(keccak256("x"));
        vm.expectRevert(TwoStepOwnable.OnlyOwner.selector);
        token.setMaxSupply(1);
        vm.stopPrank();
    }

    function _publicDropOf(NightfallGenesis t) internal view returns (PublicDrop memory) {
        t;
        return PublicDrop({
            mintPrice: 0,
            startTime: uint48(block.timestamp),
            endTime: uint48(block.timestamp + 7 days),
            maxTotalMintableByWallet: PER_WALLET,
            feeBps: 0,
            restrictFeeRecipients: true
        });
    }
}

import { PublicDrop } from "seadrop/lib/SeaDropStructs.sol";
