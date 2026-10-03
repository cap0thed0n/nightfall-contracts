// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { NightfallGenesis } from "../src/NightfallGenesis.sol";
import { CosmeticVoucherAuthority } from "../src/authority/CosmeticVoucherAuthority.sol";
import { PlaceholderArt } from "../src/art/PlaceholderArt.sol";
import { BaseTest } from "./Base.t.sol";

/// @notice The cosmetics voucher: signed by the game's dedicated cosmetics key, for one wallet,
///         one token, one cosmetic, once, before it expires.
contract CosmeticVoucherTest is BaseTest {
    uint256 internal constant HEADWEAR = 5;
    uint256 internal signerKey = 0xC05E71C5;
    uint256 internal otherKey = 0xBADBADBAD;
    CosmeticVoucherAuthority internal authority;
    uint256 internal crown;

    event VoucherSpent(uint256 indexed voucherId, address indexed player, uint256 indexed tokenId, uint256 category, uint256 layer);
    event SignerChanged(address indexed oldSigner, address indexed newSigner);

    function setUp() public override {
        super.setUp();
        mintPublic(alice, 3); // tokens 1 to 3
        mintPublic(bob, 3); // tokens 4 to 6
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
    }

    function _v(address player, uint256 tokenId, uint256 category, uint256 layer, uint256 id, uint256 expiresAt)
        internal
        pure
        returns (CosmeticVoucherAuthority.Voucher memory)
    {
        return CosmeticVoucherAuthority.Voucher(player, tokenId, category, layer, id, expiresAt);
    }

    function _sign(uint256 key, CosmeticVoucherAuthority.Voucher memory v) internal view returns (bytes memory) {
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(key, authority.voucherDigest(v));
        return abi.encode(v, abi.encodePacked(r, s, sv));
    }

    function _crownFor(address player, uint256 tokenId, uint256 id) internal view returns (bytes memory) {
        return _sign(signerKey, _v(player, tokenId, HEADWEAR, crown, id, block.timestamp + 1 hours));
    }

    // ---------------------------------------------------------------- the happy path

    function test_aValidVoucherAppliesTheCosmetic() public {
        bytes memory proof = _crownFor(alice, 2, 77);
        vm.expectEmit(true, true, true, true, address(authority));
        emit VoucherSpent(77, alice, 2, HEADWEAR, crown);
        vm.prank(alice);
        token.applyTrait(2, HEADWEAR, crown, proof);
        assertEq(token.traitsOf(2), abi.encodePacked(uint8(HEADWEAR), uint16(crown)));
        assertTrue(authority.used(77));
    }

    function test_theVoucherIsStandardTypedData() public view {
        // EIP-712: the domain and the type, so a wallet shows every field in plain words.
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Nightfall Cosmetics"),
                keccak256("1"),
                block.chainid,
                address(authority)
            )
        );
        assertEq(authority.domainSeparator(), domain);
        CosmeticVoucherAuthority.Voucher memory v = _v(alice, 2, HEADWEAR, crown, 9, 1_900_000_000);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Voucher(address player,uint256 tokenId,uint256 category,uint256 layer,uint256 voucherId,uint256 expiresAt)"),
                v.player,
                v.tokenId,
                v.category,
                v.layer,
                v.voucherId,
                v.expiresAt
            )
        );
        assertEq(authority.voucherDigest(v), keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }

    function test_aVoucherWorksUpToItsExpiry() public {
        uint256 expiresAt = block.timestamp + 60;
        bytes memory proof = _sign(signerKey, _v(alice, 1, HEADWEAR, crown, 5, expiresAt));
        vm.warp(expiresAt);
        vm.prank(alice);
        token.applyTrait(1, HEADWEAR, crown, proof);
    }

    // ---------------------------------------------------------------- every rejection

    function test_anExpiredVoucherIsRefused() public {
        uint256 expiresAt = block.timestamp + 60;
        bytes memory proof = _sign(signerKey, _v(alice, 1, HEADWEAR, crown, 5, expiresAt));
        vm.warp(expiresAt + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CosmeticVoucherAuthority.VoucherExpired.selector, 5, expiresAt));
        token.applyTrait(1, HEADWEAR, crown, proof);
    }

    function test_aVoucherIdWorksOnce() public {
        bytes memory first = _crownFor(alice, 1, 42);
        bytes memory again = _crownFor(alice, 2, 42); // same id, another token
        vm.startPrank(alice);
        token.applyTrait(1, HEADWEAR, crown, first);
        vm.expectRevert(abi.encodeWithSelector(CosmeticVoucherAuthority.VoucherAlreadyUsed.selector, 42));
        token.applyTrait(2, HEADWEAR, crown, again);
        vm.expectRevert(abi.encodeWithSelector(CosmeticVoucherAuthority.VoucherAlreadyUsed.selector, 42));
        token.applyTrait(1, HEADWEAR, crown, first);
        vm.stopPrank();
    }

    function test_aVoucherForAnotherWalletIsRefused() public {
        // Bob's voucher for token 1, submitted by Alice, who holds token 1.
        bytes memory proof = _crownFor(bob, 1, 3);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CosmeticVoucherAuthority.VoucherForAnotherWallet.selector, bob, alice));
        token.applyTrait(1, HEADWEAR, crown, proof);
    }

    function test_aVoucherForAnotherTokenIsRefused() public {
        bytes memory proof = _crownFor(alice, 2, 3);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CosmeticVoucherAuthority.VoucherForAnotherToken.selector, 2, 1));
        token.applyTrait(1, HEADWEAR, crown, proof);
    }

    function test_aVoucherForAnotherCosmeticIsRefused() public {
        bytes memory proof = _crownFor(alice, 1, 3);
        string[] memory names = new string[](1);
        names[0] = "Other";
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100;
        uint256 other = renderer.addLayers(HEADWEAR, PlaceholderArt.cosmeticCrown(), names, caps);
        uint256 elsewhere = renderer.addLayers(0, PlaceholderArt.cosmeticCrown(), names, caps);
        vm.startPrank(alice);
        // Another cosmetic in the same category.
        vm.expectRevert(abi.encodeWithSelector(CosmeticVoucherAuthority.VoucherForAnotherCosmetic.selector, HEADWEAR, crown, HEADWEAR, other));
        token.applyTrait(1, HEADWEAR, other, proof);
        // A cosmetic in another category.
        vm.expectRevert(abi.encodeWithSelector(CosmeticVoucherAuthority.VoucherForAnotherCosmetic.selector, HEADWEAR, crown, 0, elsewhere));
        token.applyTrait(1, 0, elsewhere, proof);
        vm.stopPrank();
    }

    function test_aVoucherSignedByAnyOtherKeyIsRefused() public {
        CosmeticVoucherAuthority.Voucher memory v = _v(alice, 1, HEADWEAR, crown, 3, block.timestamp + 1 hours);
        bytes memory proof = _sign(otherKey, v);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CosmeticVoucherAuthority.NotSignedByCosmeticsKey.selector, vm.addr(otherKey)));
        token.applyTrait(1, HEADWEAR, crown, proof);
    }

    function test_aVoucherEditedAfterSigningIsRefused() public {
        // Signed for the hood, then the fields rewritten to the crown: the signature no longer fits.
        CosmeticVoucherAuthority.Voucher memory v = _v(alice, 1, HEADWEAR, 1, 3, block.timestamp + 1 hours);
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(signerKey, authority.voucherDigest(v));
        v.layer = crown;
        bytes memory proof = abi.encode(v, abi.encodePacked(r, s, sv));
        vm.prank(alice);
        vm.expectPartialRevert(CosmeticVoucherAuthority.NotSignedByCosmeticsKey.selector);
        token.applyTrait(1, HEADWEAR, crown, proof);
    }

    function test_onlyTheTokenCanSpendAVoucher() public {
        bytes memory proof = _crownFor(alice, 1, 3);
        vm.prank(alice);
        vm.expectRevert(CosmeticVoucherAuthority.OnlyToken.selector);
        authority.authorize(alice, 1, HEADWEAR, crown, proof);
    }

    // ---------------------------------------------------------------- the key

    function test_aKeySwapWorksAtOnceAndVoidsTheOldKeysVouchers() public {
        bytes memory oldVoucher = _crownFor(alice, 1, 10);
        uint256 newKey = 0x5EC0ED;
        vm.expectEmit(true, true, true, true, address(authority));
        emit SignerChanged(vm.addr(signerKey), vm.addr(newKey));
        authority.setSigner(vm.addr(newKey));
        assertEq(authority.signer(), vm.addr(newKey));
        // The old key's unused voucher no longer works.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CosmeticVoucherAuthority.NotSignedByCosmeticsKey.selector, vm.addr(signerKey)));
        token.applyTrait(1, HEADWEAR, crown, oldVoucher);
        // The new key's does.
        bytes memory fresh = _sign(newKey, _v(alice, 1, HEADWEAR, crown, 11, block.timestamp + 1 hours));
        vm.prank(alice);
        token.applyTrait(1, HEADWEAR, crown, fresh);
        assertEq(token.traitsOf(1).length, 3);
    }

    function test_onlyTheOwnerSwapsTheKey() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        authority.setSigner(alice);
    }

    function test_theCosmeticsKeyMustBeItsOwnKey() public {
        vm.expectRevert(CosmeticVoucherAuthority.ZeroSigner.selector);
        authority.setSigner(address(0));
        // Never the lock operator's key, the token owner's or the authority owner's.
        vm.expectRevert(abi.encodeWithSelector(CosmeticVoucherAuthority.SignerNotDedicated.selector, operator));
        authority.setSigner(operator);
        vm.expectRevert(abi.encodeWithSelector(CosmeticVoucherAuthority.SignerNotDedicated.selector, address(this)));
        authority.setSigner(address(this));
        vm.expectRevert(abi.encodeWithSelector(CosmeticVoucherAuthority.SignerNotDedicated.selector, operator));
        new CosmeticVoucherAuthority(address(token), operator);
    }

    function test_ifTheOperatorBecomesTheCosmeticsKeyNothingItSignsCounts() public {
        bytes memory proof = _crownFor(alice, 1, 3);
        token.setOperator(vm.addr(signerKey));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CosmeticVoucherAuthority.SignerNotDedicated.selector, vm.addr(signerKey)));
        token.applyTrait(1, HEADWEAR, crown, proof);
    }
}
