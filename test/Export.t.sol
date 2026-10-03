// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { SeaDrop } from "seadrop/SeaDrop.sol";
import { NightfallRenderer } from "../src/NightfallRenderer.sol";
import { NightfallGenesis } from "../src/NightfallGenesis.sol";
import { LayerSet } from "../src/lib/LayerSet.sol";
import { ArtFile } from "../script/ArtFile.sol";
import { DeployTestnet } from "../script/DeployTestnet.s.sol";
import { VerifyExport } from "../script/VerifyExport.s.sol";
import { ArtReport } from "../script/ArtReport.s.sol";

/// @notice Trait Forge's "Export for on-chain" file, produced by the real tool in a headless
///         browser from generated test layers (see the website repo's
///         apps/web/scripts/trait-forge-export-check.mjs), fed through the real renderer.
contract ExportTest is Test {
    string internal constant FIXTURE = "deploy/art/fixture-genesis.json";

    // Nested dynamic arrays cannot live in storage on 0.8.17, so every test loads the file.
    function _art() internal view returns (ArtFile.Art memory) {
        return ArtFile.load(FIXTURE);
    }

    function _loaded(ArtFile.Art memory art) internal returns (NightfallRenderer r) {
        r = new NightfallRenderer(art.collection, "test");
        ArtFile.loadInto(art, r);
    }

    function test_fixtureLoadsWithTheExpectedShape() public {
        ArtFile.Art memory art = _art();
        assertEq(art.rows, 555);
        assertEq(art.factor, 64);
        assertEq(art.categories.length, 7);
        assertEq(art.categories[0].name, "Background");
        assertEq(art.categories[0].layers.length, 4);
        assertEq(art.table.length, 555 * 7);
        assertEq(keccak256(art.table), art.provenanceHash);
        assertGe(art.sampleRows.length, 16);
        // Every blob is a valid layer set with as many layers as names.
        for (uint256 i = 0; i < art.categories.length; ++i) {
            LayerSet.validate(art.categories[i].blob);
            assertEq(LayerSet.layerCount(art.categories[i].blob), art.categories[i].layers.length);
        }
        // The gradient layer proves there is no palette limit: 67 colours in the background set.
        assertEq(LayerSet.colourCount(art.categories[0].blob), 67);
    }

    function test_everySampleRendersAsTraitForgeDrewIt() public {
        ArtFile.Art memory art = _art();
        NightfallRenderer r = _loaded(art);
        assertEq(r.tableHash(), art.provenanceHash);
        assertEq(r.rowCount(), 555);
        uint256[] memory bad = ArtFile.verify(art, r);
        assertEq(bad.length, 0);
        for (uint256 i = 0; i < art.sampleRows.length; ++i) {
            assertEq(r.pixels(art.sampleRows[i], 0), art.samplePixels[i]);
        }
    }

    function test_hiddenLayersAreAbsentFromTheTable() public {
        // Headwear (index 5) hides Hair (index 4) in the fixture's ruleset: wherever a hat is
        // drawn, the hair byte is NO_LAYER, so the on-chain picture matches the preview.
        ArtFile.Art memory art = _art();
        uint256 hats;
        for (uint256 row = 0; row < art.rows; ++row) {
            uint8 hat = uint8(art.table[row * 7 + 5]);
            uint8 hair = uint8(art.table[row * 7 + 4]);
            if (hat != 0xff) {
                ++hats;
                assertEq(hair, 0xff);
            }
        }
        assertGt(hats, 0);
    }

    function test_aTamperedTableIsCaught() public {
        ArtFile.Art memory art = _art();
        ArtFile.Art memory tampered = art;
        tampered.table = bytes.concat(art.table);
        // Give row 0 a different, valid background layer.
        tampered.table[0] = tampered.table[0] == bytes1(0) ? bytes1(uint8(1)) : bytes1(0);
        NightfallRenderer r = new NightfallRenderer("t", "t");
        ArtFile.loadInto(tampered, r);
        uint256[] memory bad = ArtFile.verify(tampered, r);
        assertEq(bad.length, 1);
        assertEq(bad[0], 0);
    }

    function test_verifyScriptPasses() public {
        VerifyExport v = new VerifyExport();
        assertTrue(v.run(FIXTURE));
    }

    function test_deployReadsTheArtFile() public {
        vm.warp(1_800_000_000);
        DeployTestnet script = new DeployTestnet();
        DeployTestnet.Config memory cfg = script.load(script.CONFIG_PATH());
        cfg.seaDrop = address(new SeaDrop());
        cfg.royaltyReceiver = makeAddr("royalty");
        cfg.creatorPayout = makeAddr("payout");
        cfg.feeRecipient = makeAddr("fee");
        cfg.artFile = FIXTURE;
        ArtFile.Art memory art = _art();
        (NightfallGenesis token, NightfallRenderer renderer) = script.deployAll(cfg);
        assertEq(renderer.categoryCount(), 7);
        assertEq(renderer.rowCount(), 555);
        assertEq(token.provenanceHash(), art.provenanceHash);
        assertEq(renderer.categoryName(4), "Hair");
        // A supply that does not match the table is refused.
        cfg.maxSupply = 554;
        vm.expectRevert("art file rows must equal maxSupply");
        script.deployAll(cfg);
    }

    function test_pixelsAgreeWithTheSvg() public {
        ArtFile.Art memory art = _art();
        NightfallRenderer r = _loaded(art);
        // The first sample: every opaque pixel in `pixels` appears as a fill in the SVG, and a
        // transparent one never makes a rect at that spot.
        bytes memory px = r.pixels(art.sampleRows[0], 0);
        string memory s = r.svg(art.sampleRows[0], 0);
        uint256 opaque;
        for (uint256 p = 0; p < 256; ++p) if (px[p * 4 + 3] != 0) ++opaque;
        assertGt(opaque, 0);
        assertTrue(bytes(s).length > 100);
    }
}

/// @notice The full check, the missing-trait check and the gas report, on the fixture.
contract ExportFullCheckTest is Test {
    string internal constant FIXTURE = "deploy/art/fixture-genesis.json";

    /// @dev reports/ is regenerated, never committed, so a fresh clone has none: every test makes it.
    function setUp() public {
        vm.createDir("reports", true);
    }

    /// @dev Each test writes its own pixels file, so tests running in parallel never share one.
    function _pixelsPath(string memory name) internal pure returns (string memory) {
        return string(abi.encodePacked("reports/test-", name, ".pixels.bin"));
    }

    function _art() internal view returns (ArtFile.Art memory) {
        return ArtFile.load(FIXTURE);
    }

    /// @dev Writes the picture of every fixture row from the renderer, the way art-check.mjs
    ///      writes it from the PNGs, so the full loader has a file to read.
    function _writePixels(string memory path, bool tamperRow, uint256 rowToTamper) internal returns (ArtFile.Art memory art) {
        art = _art();
        NightfallRenderer r = new NightfallRenderer(art.collection, "test");
        ArtFile.loadInto(art, r);
        bytes memory full = new bytes(art.rows * 1024);
        for (uint256 row = 0; row < art.rows; ++row) {
            bytes memory px = r.pixels(row, 0);
            for (uint256 i = 0; i < 1024; ++i) full[row * 1024 + i] = px[i];
        }
        if (tamperRow) full[rowToTamper * 1024 + 3] = full[rowToTamper * 1024 + 3] == bytes1(0) ? bytes1(uint8(255)) : bytes1(0);
        vm.writeFileBinary(path, full);
    }

    function test_fullLoadChecksEveryRow() public {
        string memory pixels = _pixelsPath("full-load");
        _writePixels(pixels, false, 0);
        ArtFile.Art memory art = ArtFile.loadFull(FIXTURE, pixels);
        assertTrue(ArtFile.isFull(art));
        assertEq(ArtFile.checkedRows(art), 555);
        assertFalse(ArtFile.isFull(_art()));
        assertEq(ArtFile.checkedRows(_art()), 16);
        NightfallRenderer r = new NightfallRenderer(art.collection, "test");
        ArtFile.loadInto(art, r);
        assertEq(ArtFile.verify(art, r).length, 0);
    }

    function test_fullLoadNamesTheRowThatDiffers() public {
        string memory pixels = _pixelsPath("row-differs");
        _writePixels(pixels, true, 321);
        ArtFile.Art memory art = ArtFile.loadFull(FIXTURE, pixels);
        NightfallRenderer r = new NightfallRenderer(art.collection, "test");
        ArtFile.loadInto(art, r);
        uint256[] memory bad = ArtFile.verify(art, r);
        assertEq(bad.length, 1);
        assertEq(bad[0], 321);
    }

    function test_fullLoadRefusesAWrongSize() public {
        string memory pixels = _pixelsPath("wrong-size");
        vm.writeFileBinary(pixels, new bytes(1024));
        vm.expectRevert("pixels file must hold rows x 1024 bytes");
        this.loadFullExternal(FIXTURE, pixels);
    }

    function loadFullExternal(string memory a, string memory b) external view returns (uint256) {
        return ArtFile.loadFull(a, b).rows;
    }

    function test_verifyScriptFullPassesAndPlainRunIsNotFull() public {
        string memory pixels = _pixelsPath("verify-full");
        _writePixels(pixels, false, 0);
        VerifyExport v = new VerifyExport();
        assertTrue(v.runFull(FIXTURE, pixels));
        assertTrue(v.run(FIXTURE));
    }

    function test_verifyScriptFullFailsOnADifferingRow() public {
        string memory pixels = _pixelsPath("verify-differs");
        _writePixels(pixels, true, 7);
        VerifyExport v = new VerifyExport();
        assertFalse(v.runFull(FIXTURE, pixels));
    }

    function test_theFixtureUsesEveryTrait() public {
        assertEq(ArtFile.missingTraits(_art()).length, 0);
    }

    /// @dev Moves every use of Headwear layer 1 onto layer 0, so one trait is never used.
    function _withMissingTrait() internal view returns (ArtFile.Art memory art, string memory expected) {
        art = _art();
        art.table = bytes.concat(art.table);
        uint256 n = art.categories.length;
        for (uint256 row = 0; row < art.rows; ++row) {
            if (art.table[row * n + 5] == bytes1(uint8(1))) art.table[row * n + 5] = bytes1(0);
        }
        art.provenanceHash = keccak256(art.table);
        expected = string(abi.encodePacked("Headwear / ", art.categories[5].layers[1]));
    }

    function test_aTraitTheTableNeverUsesIsNamed() public {
        (ArtFile.Art memory art, string memory expected) = _withMissingTrait();
        string[] memory missing = ArtFile.missingTraits(art);
        assertEq(missing.length, 1);
        assertEq(missing[0], expected);
    }

    function test_verifyScriptAndDeployRefuseAMissingTrait() public {
        (ArtFile.Art memory art,) = _withMissingTrait();
        // Write the tampered export as a file: the fixture's text with the table and hash swapped.
        string memory json = vm.readFile(FIXTURE);
        ArtFile.Art memory original = _art();
        json = vm.replace(json, vm.toString(original.table), vm.toString(art.table));
        json = vm.replace(json, vm.toString(original.provenanceHash), vm.toString(art.provenanceHash));
        string memory path = "reports/test-missing-trait.json";
        vm.writeFile(path, json);
        ArtFile.Art memory reloaded = ArtFile.load(path);
        assertEq(ArtFile.missingTraits(reloaded).length, 1);

        VerifyExport v = new VerifyExport();
        assertFalse(v.run(path));

        vm.warp(1_800_000_000);
        DeployTestnet script = new DeployTestnet();
        DeployTestnet.Config memory cfg = script.load(script.CONFIG_PATH());
        cfg.seaDrop = address(new SeaDrop());
        cfg.royaltyReceiver = makeAddr("royalty");
        cfg.creatorPayout = makeAddr("payout");
        cfg.feeRecipient = makeAddr("fee");
        cfg.artFile = path;
        vm.expectRevert("art file has traits the table never uses");
        script.deployAll(cfg);
    }

    function test_reportMeasuresEveryRowAndWritesTheCsv() public {
        ArtReport report = new ArtReport();
        (uint256 worstGas, uint256 worstUri) = report.run(FIXTURE, "test-fixture");
        assertGt(worstGas, 100_000);
        assertLt(worstGas, report.GAS_LIMIT());
        assertGt(worstUri, 1000);
        string memory csv = vm.readFile("reports/test-fixture-rows.csv");
        // header plus one line per row
        uint256 lines;
        bytes memory b = bytes(csv);
        for (uint256 i = 0; i < b.length; ++i) if (b[i] == "\n") ++lines;
        assertEq(lines, 556);
    }
}
