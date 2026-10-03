// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { Base64 } from "openzeppelin-contracts/utils/Base64.sol";
import { Strings } from "openzeppelin-contracts/utils/Strings.sol";
import { BaseTest } from "./Base.t.sol";
import { NightfallRenderer } from "../src/NightfallRenderer.sol";
import { LayerSet } from "../src/lib/LayerSet.sol";
import { PlaceholderArt } from "../src/art/PlaceholderArt.sol";

contract RendererTest is BaseTest {
    string internal constant SVG_OPEN =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" shape-rendering="crispEdges">';

    uint24 internal constant A = 0x112233;
    uint24 internal constant B = 0xff2d95;

    function _one(uint24 c) internal pure returns (uint24[] memory arr) {
        arr = new uint24[](1);
        arr[0] = c;
    }

    function _names(uint256 n) internal pure returns (string[] memory arr) {
        arr = new string[](n);
        for (uint256 i = 0; i < n; ++i) arr[i] = string(abi.encodePacked("L", Strings.toString(i)));
    }

    function _layers(bytes memory l) internal pure returns (bytes[] memory arr) {
        arr = new bytes[](1);
        arr[0] = l;
    }

    /// @dev A tiny renderer: a solid background A and a 4 x 2 block of B at (4..7, 2..3).
    function _tiny() internal returns (NightfallRenderer r) {
        r = new NightfallRenderer("Tiny", "tiny");
        r.addCategory("Background", PlaceholderArt.layerSet(_one(A), _layers(PlaceholderArt.rect(PlaceholderArt.blank(), 0, 0, 15, 15, 1))), _names(1));
        r.addCategory("Body", PlaceholderArt.layerSet(_one(B), _layers(PlaceholderArt.rect(PlaceholderArt.blank(), 4, 2, 7, 3, 1))), _names(1));
        bytes memory t = new bytes(2);
        r.setTable(t); // one row, both layers index 0
    }

    function _rect(uint256 x, uint256 y, uint256 w, string memory fill) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<rect x="', Strings.toString(x), '" y="', Strings.toString(y), '" width="', Strings.toString(w),
                '" height="1" fill="#', fill, '"/>'
            )
        );
    }

    // ---------------------------------------------------------------- the reference render

    function test_svgMatchesAHandBuiltReference() public {
        NightfallRenderer r = _tiny();
        bytes memory expected = bytes(SVG_OPEN);
        for (uint256 y = 0; y < 16; ++y) {
            if (y == 2 || y == 3) {
                expected = abi.encodePacked(expected, _rect(0, y, 4, "112233"), _rect(4, y, 4, "ff2d95"), _rect(8, y, 8, "112233"));
            } else {
                expected = abi.encodePacked(expected, _rect(0, y, 16, "112233"));
            }
        }
        expected = abi.encodePacked(expected, "</svg>");
        assertEq(r.svg(0, 0), string(expected));
    }

    function test_transparentPixelsEmitNothing() public {
        NightfallRenderer r = new NightfallRenderer("T", "t");
        r.addCategory("Dot", PlaceholderArt.layerSet(_one(B), _layers(PlaceholderArt.rect(PlaceholderArt.blank(), 9, 5, 9, 5, 1))), _names(1));
        r.setTable(new bytes(1));
        assertEq(r.svg(0, 0), string(abi.encodePacked(SVG_OPEN, _rect(9, 5, 1, "ff2d95"), "</svg>")));
    }

    function test_runsMergeAcrossLayersOfTheSameColour() public {
        NightfallRenderer r = new NightfallRenderer("T", "t");
        r.addCategory("Left", PlaceholderArt.layerSet(_one(A), _layers(PlaceholderArt.rect(PlaceholderArt.blank(), 0, 0, 3, 0, 1))), _names(1));
        r.addCategory("Right", PlaceholderArt.layerSet(_one(A), _layers(PlaceholderArt.rect(PlaceholderArt.blank(), 4, 0, 7, 0, 1))), _names(1));
        r.setTable(new bytes(2));
        assertEq(r.svg(0, 0), string(abi.encodePacked(SVG_OPEN, _rect(0, 0, 8, "112233"), "</svg>")));
    }

    function test_laterLayersCoverEarlierOnes() public {
        NightfallRenderer r = _tiny();
        string memory s = r.svg(0, 0);
        assertTrue(contains(s, _rect(4, 2, 4, "ff2d95")));
        assertFalse(contains(s, _rect(0, 2, 16, "112233")));
    }

    function test_noLayerByteSkipsTheCategory() public {
        NightfallRenderer r = new NightfallRenderer("T", "t");
        r.addCategory("Background", PlaceholderArt.layerSet(_one(A), _layers(PlaceholderArt.rect(PlaceholderArt.blank(), 0, 0, 15, 15, 1))), _names(1));
        r.addCategory("Body", PlaceholderArt.layerSet(_one(B), _layers(PlaceholderArt.rect(PlaceholderArt.blank(), 4, 2, 7, 3, 1))), _names(1));
        bytes memory t = new bytes(2);
        t[1] = 0xff;
        r.setTable(t);
        assertFalse(contains(r.svg(0, 0), "ff2d95"));
        assertEq(r.tokenURI(1, true, 0, 0, ""), _expectedURI(r, "T", "t", r.svg(0, 0), '[{"trait_type":"Background","value":"L0"}]', 1));
    }

    // ---------------------------------------------------------------- no palette limit

    function test_sixtyFourColoursInOneLayer() public {
        NightfallRenderer r = new NightfallRenderer("T", "t");
        r.addCategory("Gradient", PlaceholderArt.gradientBackground(), _names(1));
        r.setTable(new bytes(1));
        string memory s = r.svg(0, 0);
        assertEq(count(s, "<rect"), 64);
        // First and last colours of the table both appear.
        assertTrue(contains(s, 'fill="#00ff3c"'));
        assertTrue(contains(s, 'fill="#fc03ba"'));
    }

    function testFuzz_layerSetRoundTrip(uint8 colourCount, bytes32 seed) public {
        uint256 n = bound(colourCount, 1, 255);
        uint24[] memory colours = new uint24[](n);
        for (uint256 i = 0; i < n; ++i) colours[i] = uint24(uint256(keccak256(abi.encodePacked(seed, i))));
        bytes memory px = PlaceholderArt.blank();
        for (uint256 p = 0; p < 256; ++p) px[p] = bytes1(uint8(uint256(keccak256(abi.encodePacked(seed, "p", p))) % (n + 1)));
        bytes memory blob = PlaceholderArt.layerSet(colours, _layers(px));
        LayerSet.validate(blob);
        assertEq(LayerSet.colourCount(blob), n);
        assertEq(LayerSet.layerCount(blob), 1);
        for (uint256 i = 1; i <= n; ++i) assertEq(LayerSet.colour(blob, i), colours[i - 1]);
        for (uint256 p = 0; p < 256; ++p) assertEq(LayerSet.pixel(blob, 0, p), uint8(px[p]));
    }

    // ---------------------------------------------------------------- validation

    function test_layerSetRefusesBadBlobs() public {
        NightfallRenderer r = new NightfallRenderer("T", "t");
        vm.expectRevert(LayerSet.EmptyLayerSet.selector);
        r.addCategory("x", "", _names(1));
        bytes memory zeroColours = new bytes(1 + 256);
        vm.expectRevert(abi.encodeWithSelector(LayerSet.BadColourCount.selector, 0));
        r.addCategory("x", zeroColours, _names(1));
        bytes memory good = PlaceholderArt.layerSet(_one(A), _layers(PlaceholderArt.blank()));
        bytes memory truncated = new bytes(good.length - 1);
        for (uint256 i = 0; i < truncated.length; ++i) truncated[i] = good[i];
        vm.expectRevert(abi.encodeWithSelector(LayerSet.MalformedLayerSet.selector, truncated.length));
        r.addCategory("x", truncated, _names(1));
        bytes memory outOfPalette = PlaceholderArt.layerSet(_one(A), _layers(PlaceholderArt.rect(PlaceholderArt.blank(), 3, 3, 3, 3, 2)));
        vm.expectRevert(abi.encodeWithSelector(LayerSet.PixelOutOfPalette.selector, 0, 51, 2, 1));
        r.addCategory("x", outOfPalette, _names(1));
        vm.expectRevert(abi.encodeWithSelector(NightfallRenderer.LayerNamesMismatch.selector, 2, 1));
        r.addCategory("x", good, _names(2));
    }

    function test_tableIsValidatedAgainstTheCategories() public {
        NightfallRenderer r = new NightfallRenderer("T", "t");
        vm.expectRevert(NightfallRenderer.NoCategories.selector);
        r.setTable(new bytes(1));
        r.addCategory("A", PlaceholderArt.layerSet(_one(A), _layers(PlaceholderArt.blank())), _names(1));
        r.addCategory("B", PlaceholderArt.layerSet(_one(B), _layers(PlaceholderArt.blank())), _names(1));
        vm.expectRevert(abi.encodeWithSelector(NightfallRenderer.TableNotDivisible.selector, 3, 2));
        r.setTable(new bytes(3));
        bytes memory t = new bytes(4);
        t[3] = 0x01; // category B has one layer, index 1 does not exist
        vm.expectRevert(abi.encodeWithSelector(NightfallRenderer.TableLayerOutOfRange.selector, 1, 1, 1));
        r.setTable(t);
        t[3] = 0xff;
        r.setTable(t);
        assertEq(r.rowCount(), 2);
        assertEq(r.tableHash(), keccak256(t));
        assertEq(r.row(1), abi.encodePacked(t[2], t[3]));
    }

    function test_tableMustBeSetBeforeRendering() public {
        NightfallRenderer r = new NightfallRenderer("T", "t");
        vm.expectRevert(NightfallRenderer.TableNotSet.selector);
        r.rowOf(1, 0);
        vm.expectRevert(NightfallRenderer.TableNotSet.selector);
        r.table();
        vm.expectRevert(NightfallRenderer.TableNotSet.selector);
        r.freeze();
    }

    function test_freezeStopsEveryChange() public {
        renderer.freeze();
        assertTrue(renderer.frozen());
        vm.expectRevert(NightfallRenderer.IsFrozen.selector);
        renderer.addCategory("x", PlaceholderArt.background(), PlaceholderArt.layerNames(0));
        vm.expectRevert(NightfallRenderer.IsFrozen.selector);
        renderer.replaceCategory(0, "x", PlaceholderArt.background(), PlaceholderArt.layerNames(0));
        vm.expectRevert(NightfallRenderer.IsFrozen.selector);
        renderer.setTable(new bytes(7));
        vm.expectRevert(NightfallRenderer.IsFrozen.selector);
        renderer.setTierColours(new uint24[](0));
        vm.expectRevert(NightfallRenderer.IsFrozen.selector);
        renderer.freeze();
        // Reading still works.
        renderer.svg(0, 0);
    }

    function test_onlyTheOwnerLoadsArt() public {
        vm.startPrank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        renderer.addCategory("x", PlaceholderArt.background(), PlaceholderArt.layerNames(0));
        vm.expectRevert("Ownable: caller is not the owner");
        renderer.setTable(new bytes(7));
        vm.expectRevert("Ownable: caller is not the owner");
        renderer.setTierColours(new uint24[](0));
        vm.expectRevert("Ownable: caller is not the owner");
        renderer.freeze();
        vm.stopPrank();
    }

    function test_replaceKeepsThePosition() public {
        NightfallRenderer r = _tiny();
        r.replaceCategory(1, "Body2", PlaceholderArt.layerSet(_one(A), _layers(PlaceholderArt.rect(PlaceholderArt.blank(), 4, 2, 7, 3, 1))), _names(1));
        assertEq(r.categoryName(1), "Body2");
        assertEq(r.categoryCount(), 2);
        // Same colour as the background now, so the block merges away.
        assertEq(count(r.svg(0, 0), "<rect"), 16);
        vm.expectRevert(abi.encodeWithSelector(NightfallRenderer.CategoryOutOfRange.selector, 2));
        r.replaceCategory(2, "x", PlaceholderArt.background(), PlaceholderArt.layerNames(0));
    }

    // ---------------------------------------------------------------- the tier border

    function _tiers() internal pure returns (uint24[] memory t) {
        t = new uint24[](3);
        t[0] = 0xffffff;
        t[1] = 0x2fbf71;
        t[2] = 0x9b5de5;
    }

    function test_borderIsDrawnLastAroundTheEdge() public {
        NightfallRenderer r = _tiny();
        r.setTierColours(_tiers());
        string memory s = r.svg(0, 1);
        assertTrue(contains(s, _rect(0, 0, 16, "ffffff")));
        assertTrue(contains(s, _rect(0, 15, 16, "ffffff")));
        // Middle rows: one border pixel, the art, one border pixel.
        assertTrue(contains(s, string(abi.encodePacked(_rect(0, 5, 1, "ffffff"), _rect(1, 5, 14, "112233"), _rect(15, 5, 1, "ffffff")))));
        // Tier 2 and 3 use their own colours; tier 0 and an unknown tier draw none.
        assertTrue(contains(r.svg(0, 2), _rect(0, 0, 16, "2fbf71")));
        assertTrue(contains(r.svg(0, 3), _rect(0, 0, 16, "9b5de5")));
        assertFalse(contains(r.svg(0, 0), "ffffff"));
        assertFalse(contains(r.svg(0, 4), "ffffff"));
        assertEq(r.tierColours().length, 3);
    }

    function test_borderCoversTheArtBeneath() public {
        NightfallRenderer r = new NightfallRenderer("T", "t");
        r.addCategory("Edge", PlaceholderArt.layerSet(_one(B), _layers(PlaceholderArt.rect(PlaceholderArt.blank(), 0, 0, 15, 0, 1))), _names(1));
        r.setTable(new bytes(1));
        r.setTierColours(_tiers());
        assertEq(r.svg(0, 1), string(abi.encodePacked(SVG_OPEN, _borderOnly("ffffff"), "</svg>")));
    }

    function _borderOnly(string memory fill) internal pure returns (bytes memory out) {
        out = abi.encodePacked(_rect(0, 0, 16, fill));
        for (uint256 y = 1; y < 15; ++y) out = abi.encodePacked(out, _rect(0, y, 1, fill), _rect(15, y, 1, fill));
        out = abi.encodePacked(out, _rect(0, 15, 16, fill));
    }

    function test_atMostFifteenTiers() public {
        vm.expectRevert(abi.encodeWithSelector(NightfallRenderer.TooManyTiers.selector, 16));
        renderer.setTierColours(new uint24[](16));
    }

    // ---------------------------------------------------------------- metadata

    function _expectedURI(NightfallRenderer r, string memory name, string memory desc, string memory image, string memory attributes, uint256 id)
        internal
        pure
        returns (string memory)
    {
        r;
        bytes memory json = abi.encodePacked(
            '{"name":"', name, " #", Strings.toString(id), '","description":"', desc,
            '","image":"data:image/svg+xml;base64,', Base64.encode(bytes(image)), '","attributes":', attributes, "}"
        );
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(json)));
    }

    function test_revealedMetadataCarriesTheTraits() public {
        NightfallRenderer r = _tiny();
        assertEq(
            r.tokenURI(7, true, 0, 0, ""),
            _expectedURI(r, "Tiny", "tiny", r.svg(0, 0), '[{"trait_type":"Background","value":"L0"},{"trait_type":"Body","value":"L0"}]', 7)
        );
    }

    function test_unrevealedMetadataHasNoTraitsAndAFixedImage() public {
        assertEq(
            renderer.tokenURI(3, false, 12345, 0, ""),
            _expectedURI(renderer, "Nightfall Genesis", "A boss of the network.", renderer.unrevealedSvg(), "[]", 3)
        );
        // The same for every token and every offset.
        assertEq(
            keccak256(bytes(renderer.tokenURI(3, false, 1, 0, ""))),
            keccak256(bytes(renderer.tokenURI(3, false, 999, 0, "")))
        );
        assertTrue(startsWith(renderer.unrevealedSvg(), SVG_OPEN));
    }

    function test_placeholderSetLoadsAndRenders() public {
        assertEq(renderer.categoryCount(), 7);
        assertEq(renderer.categoryName(0), "Background");
        assertEq(renderer.categoryName(6), "Face Accessory");
        assertEq(renderer.rowCount(), MAX_SUPPLY);
        assertEq(renderer.layerNames(0).length, 3);
        assertEq(renderer.layerSet(0), PlaceholderArt.background());
        string memory s = renderer.svg(0, 0);
        assertTrue(startsWith(s, SVG_OPEN));
        assertGt(count(s, "<rect"), 16); // background rows plus the figure
    }

    function test_rowOfWrapsAroundTheTable() public {
        assertEq(renderer.rowOf(1, 0), 1);
        assertEq(renderer.rowOf(1, MAX_SUPPLY - 1), 0);
        assertEq(renderer.rowOf(MAX_SUPPLY, 0), 0);
        assertEq(renderer.rowOf(555, 554), 554);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_everyRowAndTierRenders(uint256 rowIndex, uint8 tier) public {
        rowIndex = bound(rowIndex, 0, MAX_SUPPLY - 1);
        renderer.setTierColours(_tiers());
        string memory s = renderer.svg(rowIndex, tier);
        assertTrue(startsWith(s, SVG_OPEN));
        uint256 rects = count(s, "<rect");
        assertGe(rects, 16); // the background always fills every row
        assertLe(rects, 256);
        bool hasBorder = tier >= 1 && tier <= 3;
        assertEq(contains(s, _rect(0, 0, 16, tier == 1 ? "ffffff" : tier == 2 ? "2fbf71" : "9b5de5")), hasBorder);
    }

    function testFuzz_anySeedGivesAValidTable(bytes32 seed, uint16 rows) public {
        rows = uint16(bound(rows, 1, 600));
        NightfallRenderer r = new NightfallRenderer("T", "t");
        loadPlaceholders(r);
        r.setTable(PlaceholderArt.table(rows, seed));
        assertEq(r.rowCount(), rows);
        // Headwear suppresses hair in every row.
        bytes memory t = r.table();
        for (uint256 i = 0; i < rows; ++i) {
            if (uint8(t[i * 7 + 5]) != 0xff) assertEq(uint8(t[i * 7 + 3]), 0xff);
        }
    }

    function testFuzz_tokenURIIsDeterministic(uint256 tokenId, uint256 offset, uint8 tier) public {
        // Any token id and any offset, including ones no reveal could produce: the renderer
        // never reverts and never overflows.
        string memory a = renderer.tokenURI(tokenId, true, offset, tier, "");
        string memory b = renderer.tokenURI(tokenId, true, offset, tier, "");
        assertEq(a, b);
        assertTrue(startsWith(a, "data:application/json;base64,"));
    }
}
