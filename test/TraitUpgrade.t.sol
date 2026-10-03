// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { TwoStepOwnable } from "utility-contracts/TwoStepOwnable.sol";
import { NightfallGenesis } from "../src/NightfallGenesis.sol";
import { NightfallRenderer } from "../src/NightfallRenderer.sol";
import { CosmeticVoucherAuthority } from "../src/authority/CosmeticVoucherAuthority.sol";
import { PlaceholderArt } from "../src/art/PlaceholderArt.sol";
import { BaseTest } from "./Base.t.sol";

/// @notice Cosmetic upgrades: new traits uploaded to an existing category over time, applied
///         by a holder to a revealed token, replacing that category's trait and nothing else.
contract TraitUpgradeTest is BaseTest {
    uint256 internal constant HEADWEAR = 5;
    CosmeticVoucherAuthority internal authority;
    uint256 internal signerKey = 0xC0517E71C5;
    uint256 internal nextVoucherId = 1;
    uint256 internal crown;
    /// @dev The supply cap the test cosmetics upload with.
    uint256 internal constant CAP = 100;

    event MetadataUpdate(uint256 _tokenId);

    function setUp() public override {
        super.setUp();
        mintPublic(alice, 5);
        mintPublic(bob, 5);
        token.closeMint();
        uint256 target = token.revealTargetBlock();
        vm.roll(target + 1);
        vm.setBlockhash(target, keccak256("target hash"));
        token.captureEntropy();
        token.reveal(DEFAULT_SECRET);

        authority = new CosmeticVoucherAuthority(address(token), vm.addr(signerKey));
        token.setTraitAuthority(address(authority));
        crown = renderer.addLayers(HEADWEAR, PlaceholderArt.cosmeticCrown(), _names("Test Crown", 1), _caps(1, CAP));
    }

    function _names(string memory base, uint256 n) internal pure returns (string[] memory names) {
        names = new string[](n);
        for (uint256 i = 0; i < n; ++i) names[i] = n == 1 ? base : string(abi.encodePacked(base, " ", _digit(i)));
    }

    function _caps(uint256 n, uint256 cap) internal pure returns (uint256[] memory caps) {
        caps = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) caps[i] = cap;
    }

    function _digit(uint256 i) internal pure returns (string memory) {
        bytes memory b = new bytes(3);
        b[0] = bytes1(uint8(48 + (i / 100) % 10));
        b[1] = bytes1(uint8(48 + (i / 10) % 10));
        b[2] = bytes1(uint8(48 + i % 10));
        return string(b);
    }

    /// @dev A voucher from the game's cosmetics key for this wallet, token and cosmetic, as the
    ///      proof `applyTrait` takes.
    function _voucher(address player, uint256 id, uint256 category, uint256 layer) internal returns (bytes memory) {
        CosmeticVoucherAuthority.Voucher memory v = CosmeticVoucherAuthority.Voucher(player, id, category, layer, nextVoucherId++, block.timestamp + 1 hours);
        (uint8 vv, bytes32 r, bytes32 ss) = vm.sign(signerKey, authority.voucherDigest(v));
        return abi.encode(v, abi.encodePacked(r, ss, vv));
    }

    function _row(uint256 id) internal view returns (uint256) {
        return renderer.rowOf(id, token.revealOffset());
    }

    // ---------------------------------------------------------------- uploading

    function test_aNewTraitJoinsItsCategoryAfterEveryExistingOne() public {
        assertEq(crown, 2); // Headwear had two placeholder layers
        assertEq(renderer.layerCount(HEADWEAR), 3);
        assertEq(renderer.chunkCount(HEADWEAR), 2);
        assertEq(renderer.layerNames(HEADWEAR)[2], "Test Crown");
        assertEq(renderer.categoryCount(), 7); // no category added
        assertEq(keccak256(renderer.layerSetChunk(HEADWEAR, 1)), keccak256(PlaceholderArt.cosmeticCrown()));
    }

    function test_uploadingIsOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        renderer.addLayers(HEADWEAR, PlaceholderArt.cosmeticCrown(), _names("x", 1), _caps(1, CAP));
    }

    function test_uploadingNeedsAnExistingCategory() public {
        vm.expectRevert(abi.encodeWithSelector(NightfallRenderer.CategoryOutOfRange.selector, 7));
        renderer.addLayers(7, PlaceholderArt.cosmeticCrown(), _names("x", 1), _caps(1, CAP));
    }

    // ---------------------------------------------------------------- applying

    function test_applyingReplacesTheTraitAndNothingElse() public {
        uint256 id = 3;
        uint256[] memory before = renderer.layersOf(_row(id), "");
        string memory uriBefore = token.tokenURI(id);
        bytes memory proof = _voucher(alice, id, HEADWEAR, crown);

        vm.expectEmit(true, true, true, true);
        emit MetadataUpdate(id);
        vm.prank(alice);
        token.applyTrait(id, HEADWEAR, crown, proof);

        uint256[] memory afterLayers = renderer.layersOf(_row(id), token.traitsOf(id));
        for (uint256 c = 0; c < before.length; ++c) {
            if (c == HEADWEAR) assertEq(afterLayers[c], crown);
            else assertEq(afterLayers[c], before[c]);
        }
        string memory uri = token.tokenURI(id);
        assertTrue(keccak256(bytes(uri)) != keccak256(bytes(uriBefore)));
        // The metadata names the new trait, and the image is the row drawn with it.
        bytes memory traits = abi.encodePacked(uint8(HEADWEAR), uint16(crown));
        assertEq(uri, renderer.tokenURI(id, true, token.revealOffset(), 0, traits));
        assertTrue(contains(_decodedJson(id), '{"trait_type":"Headwear","value":"Test Crown"}'));
        // Everything else about the token is unchanged.
        assertEq(token.ownerOf(id), alice);
        assertEq(_row(id), renderer.rowOf(id, token.revealOffset()));
        assertEq(token.totalSupply(), 10);
    }

    function test_theMetadataSwapsTheValueInPlaceWithNothingAdded() public {
        // A token whose row shows a Headwear layer, so there is a value to replace.
        uint256 id = 1;
        while (renderer.layersOf(_row(id), "")[HEADWEAR] == type(uint256).max) ++id;
        uint256 shown = renderer.layersOf(_row(id), "")[HEADWEAR];
        string memory beforeJson = _decodedJson(id);
        string memory oldPair = string(abi.encodePacked('{"trait_type":"Headwear","value":"', renderer.layerNames(HEADWEAR)[shown], '"}'));
        assertTrue(contains(beforeJson, oldPair));

        bytes memory proof = _voucher(token.ownerOf(id), id, HEADWEAR, crown);
        vm.prank(token.ownerOf(id));
        token.applyTrait(id, HEADWEAR, crown, proof);

        string memory afterJson = _decodedJson(id);
        // The same number of attributes, Headwear now names the cosmetic, the old value is gone.
        assertEq(_count(afterJson, '"trait_type"'), _count(beforeJson, '"trait_type"'));
        assertEq(_count(afterJson, '"trait_type":"Headwear"'), 1);
        assertTrue(contains(afterJson, '{"trait_type":"Headwear","value":"Test Crown"}'));
        assertFalse(contains(afterJson, oldPair));
        // No separate cosmetic slot and no marker for modified or untouched tokens.
        assertFalse(contains(afterJson, "Cosmetic"));
        assertFalse(contains(afterJson, "Untouched"));
        assertFalse(contains(afterJson, "Original"));
        assertFalse(contains(beforeJson, "Untouched"));
        assertFalse(contains(beforeJson, "Original"));
    }

    function _count(string memory s, string memory needle) internal pure returns (uint256 n) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(needle);
        for (uint256 i = 0; i + b.length <= a.length; ++i) {
            bool ok = true;
            for (uint256 j = 0; j < b.length; ++j) {
                if (a[i + j] != b[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) ++n;
        }
    }

    function test_theImageShowsTheCrownPixels() public {
        bytes memory proof = _voucher(alice, 1, HEADWEAR, crown);
        vm.prank(alice);
        token.applyTrait(1, HEADWEAR, crown, proof);
        string memory svg = _svgOf(1);
        assertTrue(contains(svg, 'fill="#ffd23f"'));
        assertTrue(contains(svg, 'fill="#ff2d95"'));
    }

    function test_aSecondCosmeticReplacesTheFirstNeverStacks() public {
        uint256 hood = renderer.addLayers(HEADWEAR, PlaceholderArt.cosmeticCrown(), _names("Test Hood", 1), _caps(1, CAP));
        bytes memory first = _voucher(alice, 2, HEADWEAR, crown);
        bytes memory second = _voucher(alice, 2, HEADWEAR, hood);
        vm.startPrank(alice);
        token.applyTrait(2, HEADWEAR, crown, first);
        token.applyTrait(2, HEADWEAR, hood, second);
        vm.stopPrank();
        assertEq(token.traitsOf(2), abi.encodePacked(uint8(HEADWEAR), uint16(hood)));
        assertEq(renderer.layersOf(_row(2), token.traitsOf(2))[HEADWEAR], hood);
    }

    function test_upgradesTravelWithTheToken() public {
        bytes memory proof = _voucher(alice, 4, HEADWEAR, crown);
        vm.prank(alice);
        token.applyTrait(4, HEADWEAR, crown, proof);
        string memory uri = token.tokenURI(4);
        vm.prank(alice);
        token.transferFrom(alice, carol, 4);
        assertEq(token.tokenURI(4), uri);
    }

    function test_onlyTheHolderApplies() public {
        bytes memory proof = _voucher(bob, 1, HEADWEAR, crown);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.NotTokenHolder.selector, 1));
        token.applyTrait(1, HEADWEAR, crown, proof);
    }

    function test_withoutAVoucherItIsRefused() public {
        vm.prank(alice);
        vm.expectRevert();
        token.applyTrait(1, HEADWEAR, crown, "");
    }

    function test_theAuthorityAcceptsOnlyTheToken() public {
        bytes memory proof = _voucher(alice, 1, HEADWEAR, crown);
        vm.expectRevert(CosmeticVoucherAuthority.OnlyToken.selector);
        authority.authorize(alice, 1, HEADWEAR, crown, proof);
    }

    function test_aTraitThatDoesNotExistIsRefused() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.NoSuchTrait.selector, HEADWEAR, 3));
        token.applyTrait(1, HEADWEAR, 3, "");
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.NoSuchTrait.selector, 7, 0));
        token.applyTrait(1, 7, 0, "");
        vm.stopPrank();
    }

    function test_upgradesAreOffWithoutAnAuthority() public {
        token.setTraitAuthority(address(0));
        vm.prank(alice);
        vm.expectRevert(NightfallGenesis.UpgradesOff.selector);
        token.applyTrait(1, HEADWEAR, crown, "");
    }

    function test_settingTheAuthorityIsOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.OnlyOwner.selector);
        token.setTraitAuthority(alice);
    }

    // ---------------------------------------------------------------- nothing blocks upgrades

    function test_theFreezeFixesTheBaseArtButNeverTheCosmetics() public {
        renderer.freeze();
        // The base art is final.
        vm.expectRevert(NightfallRenderer.IsFrozen.selector);
        renderer.addCategory("x", PlaceholderArt.cosmeticCrown(), _names("x", 1));
        vm.expectRevert(NightfallRenderer.IsFrozen.selector);
        renderer.replaceCategory(HEADWEAR, "x", PlaceholderArt.cosmeticCrown(), _names("x", 1));
        vm.expectRevert(NightfallRenderer.IsFrozen.selector);
        renderer.setTable(new bytes(7));
        // New cosmetics still upload, and still apply.
        uint256 second = renderer.addLayers(HEADWEAR, PlaceholderArt.cosmeticCrown(), _names("Test Crown II", 1), _caps(1, CAP));
        bytes memory proof = _voucher(alice, 1, HEADWEAR, second);
        vm.prank(alice);
        token.applyTrait(1, HEADWEAR, second, proof);
        assertEq(renderer.layersOf(_row(1), token.traitsOf(1))[HEADWEAR], second);
    }

    function test_lockedTokensCanStillBeUpgraded() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint64[] memory untils = new uint64[](1);
        untils[0] = uint64(block.timestamp + 1 hours);
        vm.prank(operator);
        token.lockUntil(ids, untils);
        bytes memory proof = _voucher(alice, 1, HEADWEAR, crown);
        vm.prank(alice);
        token.applyTrait(1, HEADWEAR, crown, proof);
        assertEq(token.traitsOf(1).length, 3);
    }

    // ---------------------------------------------------------------- supply caps

    function test_aCapIsSetForEachCosmeticAtUpload() public {
        assertEq(renderer.cosmeticCap(HEADWEAR, crown), CAP);
        uint256[] memory caps = new uint256[](2);
        caps[0] = 3;
        caps[1] = 7;
        uint24[] memory colours = new uint24[](1);
        colours[0] = 0x2de2ff;
        bytes[] memory layers = new bytes[](2);
        layers[0] = PlaceholderArt.blank();
        layers[1] = PlaceholderArt.blank();
        uint256 first = renderer.addLayers(HEADWEAR, PlaceholderArt.layerSet(colours, layers), _names("Pair", 2), caps);
        assertEq(renderer.cosmeticCap(HEADWEAR, first), 3);
        assertEq(renderer.cosmeticCap(HEADWEAR, first + 1), 7);
        // A base layer has no cap.
        assertEq(renderer.cosmeticCap(HEADWEAR, 0), 0);
    }

    function test_everyUploadedCosmeticNeedsACapOfAtLeastOne() public {
        vm.expectRevert(abi.encodeWithSelector(NightfallRenderer.CapsMismatch.selector, 0, 1));
        renderer.addLayers(HEADWEAR, PlaceholderArt.cosmeticCrown(), _names("x", 1), new uint256[](0));
        vm.expectRevert(abi.encodeWithSelector(NightfallRenderer.ZeroCap.selector, HEADWEAR, 3));
        renderer.addLayers(HEADWEAR, PlaceholderArt.cosmeticCrown(), _names("x", 1), _caps(1, 0));
    }

    function test_applyingStopsAtTheCap() public {
        uint256 rare = renderer.addLayers(HEADWEAR, PlaceholderArt.cosmeticCrown(), _names("Rare Crown", 1), _caps(1, 2));
        bytes memory p1 = _voucher(alice, 1, HEADWEAR, rare);
        bytes memory p2 = _voucher(alice, 2, HEADWEAR, rare);
        bytes memory p3 = _voucher(alice, 3, HEADWEAR, rare);
        vm.startPrank(alice);
        token.applyTrait(1, HEADWEAR, rare, p1);
        token.applyTrait(2, HEADWEAR, rare, p2);
        assertEq(token.cosmeticApplied((HEADWEAR << 16) | rare), 2);
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.CosmeticSoldOut.selector, HEADWEAR, rare, 2));
        token.applyTrait(3, HEADWEAR, rare, p3);
        vm.stopPrank();
        // The refused apply spent nothing: its voucher stays unspent.
        (CosmeticVoucherAuthority.Voucher memory v3, ) = abi.decode(p3, (CosmeticVoucherAuthority.Voucher, bytes));
        assertFalse(authority.used(v3.voucherId));
        assertEq(token.traitsOf(3).length, 0);
    }

    function test_replacingACosmeticDoesNotFreeItsSlot() public {
        uint256 rare = renderer.addLayers(HEADWEAR, PlaceholderArt.cosmeticCrown(), _names("Rare Crown", 1), _caps(1, 1));
        bytes memory p1 = _voucher(alice, 1, HEADWEAR, rare);
        bytes memory p2 = _voucher(alice, 1, HEADWEAR, crown);
        bytes memory p3 = _voucher(alice, 2, HEADWEAR, rare);
        vm.startPrank(alice);
        token.applyTrait(1, HEADWEAR, rare, p1);
        token.applyTrait(1, HEADWEAR, crown, p2);
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.CosmeticSoldOut.selector, HEADWEAR, rare, 1));
        token.applyTrait(2, HEADWEAR, rare, p3);
        vm.stopPrank();
    }

    function test_aBaseLayerIsNeverAppliedAsACosmetic() public {
        bytes memory proof = _voucher(alice, 1, HEADWEAR, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NightfallGenesis.NotACosmetic.selector, HEADWEAR, 1));
        token.applyTrait(1, HEADWEAR, 1, proof);
    }

    // ---------------------------------------------------------------- hundreds per category

    function test_aCategoryHoldsHundredsOfCosmetics() public {
        // Four chunks of ninety layers each, well past the 255 a table byte could name.
        uint24[] memory colours = new uint24[](1);
        colours[0] = 0x2de2ff;
        for (uint256 k = 0; k < 4; ++k) {
            bytes[] memory layers = new bytes[](90);
            for (uint256 i = 0; i < 90; ++i) {
                bytes memory px = PlaceholderArt.blank();
                px[(k * 90 + i) % 256] = bytes1(uint8(1));
                layers[i] = px;
            }
            renderer.addLayers(HEADWEAR, PlaceholderArt.layerSet(colours, layers), _names("Band", 90), _caps(90, CAP));
        }
        assertEq(renderer.layerCount(HEADWEAR), 3 + 360);
        assertEq(renderer.chunkCount(HEADWEAR), 6);
        uint256 far = 3 + 3 * 90 + 45; // in the last chunk, index 318
        bytes memory proof = _voucher(alice, 1, HEADWEAR, far);
        vm.prank(alice);
        token.applyTrait(1, HEADWEAR, far, proof);
        assertEq(renderer.layersOf(_row(1), token.traitsOf(1))[HEADWEAR], far);
        // The right pixel of the right layer is drawn: layer 318 is band k=3, i=45, pixel 315 % 256.
        bytes memory px = renderer.pixelsWithTraits(_row(1), 0, token.traitsOf(1));
        assertEq(uint8(px[((3 * 90 + 45) % 256) * 4 + 3]), 255);
        uint256 gasBefore = gasleft();
        token.tokenURI(1);
        assertLt(gasBefore - gasleft(), 5_000_000);
    }

    function test_tooManyLayersInOneCategoryAreRefused() public view {
        assertEq(renderer.MAX_LAYERS_PER_CATEGORY(), 65_535);
        assertEq(renderer.MAX_CATEGORIES(), 256);
    }

    // ---------------------------------------------------------------- helpers

    function _decodedJson(uint256 id) internal view returns (string memory) {
        uint256[] memory layers = renderer.layersOf(_row(id), token.traitsOf(id));
        return renderer.attributesOf(layers);
    }

    function _svgOf(uint256 id) internal view returns (string memory) {
        return renderer.svgWithTraits(_row(id), 0, token.traitsOf(id));
    }
}
