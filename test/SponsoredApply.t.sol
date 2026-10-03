// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { NightfallGenesis } from "../src/NightfallGenesis.sol";
import { CosmeticVoucherAuthority } from "../src/authority/CosmeticVoucherAuthority.sol";
import { SponsoredApplier } from "../src/authority/SponsoredApplier.sol";
import { PlaceholderArt } from "../src/art/PlaceholderArt.sol";
import { BaseTest } from "./Base.t.sol";

/// @notice The project-pays-gas path: built, off by default on both sides, and when turned on
///         it applies a cosmetic only with the player's own signature and every check the
///         token makes on `applyTrait`.
contract SponsoredApplyTest is BaseTest {
    uint256 internal constant HEADWEAR = 5;
    CosmeticVoucherAuthority internal authority;
    SponsoredApplier internal applier;
    uint256 internal signerKey = 0xC0517E71C5;
    uint256 internal playerKey = 0xA11CE;
    address internal player;
    address internal relayer = makeAddr("relayer");
    uint256 internal nextVoucherId = 1;
    uint256 internal crown;
    uint256 internal firstId;

    event TraitApplied(uint256 indexed tokenId, uint256 indexed category, uint256 layer, address indexed player);

    function setUp() public override {
        super.setUp();
        player = vm.addr(playerKey);
        firstId = token.totalSupply() + 1;
        mintPublic(player, 3);
        mintPublic(bob, 3);
        token.closeMint();
        uint256 target = token.revealTargetBlock();
        vm.roll(target + 1);
        vm.setBlockhash(target, keccak256("target hash"));
        token.captureEntropy();
        token.reveal(DEFAULT_SECRET);
        authority = new CosmeticVoucherAuthority(address(token), vm.addr(signerKey));
        token.setTraitAuthority(address(authority));
        string[] memory names = new string[](1);
        names[0] = "Test Crown";
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100;
        crown = renderer.addLayers(HEADWEAR, PlaceholderArt.cosmeticCrown(), names, caps);
        applier = new SponsoredApplier(address(token));
    }

    function _turnOn() internal {
        token.setSponsor(address(applier));
        applier.setEnabled(true);
        applier.setRelayer(relayer, true);
    }

    function _voucher(address who, uint256 tokenId) internal returns (bytes memory) {
        CosmeticVoucherAuthority.Voucher memory v = CosmeticVoucherAuthority.Voucher(who, tokenId, HEADWEAR, crown, nextVoucherId++, block.timestamp + 1 hours);
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(signerKey, authority.voucherDigest(v));
        return abi.encode(v, abi.encodePacked(r, s, vv));
    }

    function _request(address who, uint256 tokenId, bytes memory proof) internal view returns (SponsoredApplier.Request memory) {
        return SponsoredApplier.Request(who, tokenId, HEADWEAR, crown, keccak256(proof), block.timestamp + 10 minutes);
    }

    function _sign(uint256 key, SponsoredApplier.Request memory r) internal view returns (bytes memory) {
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(key, applier.requestDigest(r));
        return abi.encodePacked(rr, s, v);
    }

    // ---------------------------------------------------------------- off by default

    function test_offByDefaultOnBothSides() public {
        assertEq(token.sponsor(), address(0));
        assertFalse(applier.enabled());
        bytes memory proof = _voucher(player, firstId);
        SponsoredApplier.Request memory r = _request(player, firstId, proof);
        bytes memory sig = _sign(playerKey, r);
        vm.prank(relayer);
        vm.expectRevert(SponsoredApplier.SponsoringOff.selector);
        applier.submit(r, proof, sig);
        // Even switched on, the token refuses it until the owner names this contract its sponsor.
        applier.setEnabled(true);
        applier.setRelayer(relayer, true);
        vm.prank(relayer);
        vm.expectRevert(NightfallGenesis.NotSponsor.selector);
        applier.submit(r, proof, sig);
    }

    function test_onlyTheSponsorCallsApplyTraitFor() public {
        _turnOn();
        bytes memory proof = _voucher(player, firstId);
        vm.prank(player);
        vm.expectRevert(NightfallGenesis.NotSponsor.selector);
        token.applyTraitFor(player, firstId, HEADWEAR, crown, proof);
    }

    function test_settingTheSponsorIsOwnerOnlyAndZeroTurnsItOff() public {
        vm.prank(bob);
        vm.expectRevert();
        token.setSponsor(address(applier));
        _turnOn();
        token.setSponsor(address(0));
        bytes memory proof = _voucher(player, firstId);
        SponsoredApplier.Request memory r = _request(player, firstId, proof);
        bytes memory sig = _sign(playerKey, r);
        vm.prank(relayer);
        vm.expectRevert(NightfallGenesis.NotSponsor.selector);
        applier.submit(r, proof, sig);
    }

    // ---------------------------------------------------------------- on

    function test_theRelayerPaysAndThePlayerGetsTheCosmetic() public {
        _turnOn();
        bytes memory proof = _voucher(player, firstId);
        SponsoredApplier.Request memory r = _request(player, firstId, proof);
        bytes memory sig = _sign(playerKey, r);
        uint256 playerBalance = player.balance;
        vm.expectEmit(true, true, true, true, address(token));
        emit TraitApplied(firstId, HEADWEAR, crown, player);
        vm.prank(relayer);
        applier.submit(r, proof, sig);
        assertEq(token.traitsOf(firstId), abi.encodePacked(uint8(HEADWEAR), uint16(crown)));
        assertEq(player.balance, playerBalance);
        assertEq(token.cosmeticApplied((HEADWEAR << 16) | crown), 1);
    }

    function test_onlyARelayerSubmits() public {
        _turnOn();
        bytes memory proof = _voucher(player, firstId);
        SponsoredApplier.Request memory r = _request(player, firstId, proof);
        bytes memory sig = _sign(playerKey, r);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SponsoredApplier.NotRelayer.selector, bob));
        applier.submit(r, proof, sig);
    }

    function test_thePlayerMustSign() public {
        _turnOn();
        bytes memory proof = _voucher(player, firstId);
        SponsoredApplier.Request memory r = _request(player, firstId, proof);
        bytes memory sig = _sign(0xB0B, r);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(SponsoredApplier.NotSignedByPlayer.selector, player));
        applier.submit(r, proof, sig);
    }

    function test_theRelayerCannotSwapTheVoucher() public {
        _turnOn();
        bytes memory proof = _voucher(player, firstId);
        bytes memory other = _voucher(player, firstId);
        SponsoredApplier.Request memory r = _request(player, firstId, proof);
        bytes memory sig = _sign(playerKey, r);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(SponsoredApplier.NotSignedByPlayer.selector, player));
        applier.submit(r, other, sig);
    }

    function test_anExpiredRequestIsRefused() public {
        _turnOn();
        bytes memory proof = _voucher(player, firstId);
        SponsoredApplier.Request memory r = _request(player, firstId, proof);
        bytes memory sig = _sign(playerKey, r);
        vm.warp(r.deadline + 1);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(SponsoredApplier.RequestExpired.selector, r.deadline));
        applier.submit(r, proof, sig);
    }

    function test_aRequestWorksOnce() public {
        _turnOn();
        bytes memory proof = _voucher(player, firstId);
        SponsoredApplier.Request memory r = _request(player, firstId, proof);
        bytes memory sig = _sign(playerKey, r);
        vm.startPrank(relayer);
        applier.submit(r, proof, sig);
        vm.expectRevert(abi.encodeWithSelector(CosmeticVoucherAuthority.VoucherAlreadyUsed.selector, 1));
        applier.submit(r, proof, sig);
        vm.stopPrank();
    }

    function test_thePlayerMustHoldTheToken() public {
        _turnOn();
        uint256 bobs = firstId + 3;
        assertEq(token.ownerOf(bobs), bob);
        bytes memory proof = _voucher(player, bobs);
        SponsoredApplier.Request memory r = _request(player, bobs, proof);
        bytes memory sig = _sign(playerKey, r);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.NotTokenHolder.selector, bobs));
        applier.submit(r, proof, sig);
    }

    function test_settingsAreOwnerOnly() public {
        vm.startPrank(bob);
        vm.expectRevert("Ownable: caller is not the owner");
        applier.setEnabled(true);
        vm.expectRevert("Ownable: caller is not the owner");
        applier.setRelayer(bob, true);
        vm.stopPrank();
    }
}
