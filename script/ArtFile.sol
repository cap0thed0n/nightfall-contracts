// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Vm } from "forge-std/Vm.sol";
import { NightfallRenderer } from "../src/NightfallRenderer.sol";
import { LayerSet } from "../src/lib/LayerSet.sol";

/**
 * @notice Reads Trait Forge's "Export for on-chain" file (format `nightfall-onchain-art`,
 *         version 1) and loads it into a renderer. `deploy/art/fixture-genesis.json` is an example
 *         of the format, and `tools/lib/artfile.mjs` reads it the same way. Used by the deploy
 *         script and by the export checker.
 */
library ArtFile {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Category {
        string name;
        string[] layers;
        bytes blob;
    }

    struct Art {
        string collection;
        uint256 factor;
        Category[] categories;
        uint256 rows;
        bytes table;
        bytes32 provenanceHash;
        uint256[] sampleRows;
        bytes[] samplePixels;
        /// rows x 1024 bytes of RGBA, one 16 x 16 picture per row, from tools/art-check.mjs.
        /// Empty unless loaded with `loadFull`. Kept as one buffer: the EVM's memory cost is
        /// quadratic, so 555 pictures live in one allocation, never one JSON value each.
        bytes fullPixels;
    }

    function load(string memory path) internal view returns (Art memory a) {
        string memory json = vm.readFile(path);
        require(
            keccak256(bytes(vm.parseJsonString(json, ".format"))) == keccak256("nightfall-onchain-art"),
            "not a nightfall-onchain-art file"
        );
        require(vm.parseJsonUint(json, ".version") == 1, "unsupported art file version");
        a.collection = vm.parseJsonString(json, ".collection");
        a.factor = vm.parseJsonUint(json, ".source.factor");
        a.rows = vm.parseJsonUint(json, ".rows");
        a.table = vm.parseJsonBytes(json, ".table");
        a.provenanceHash = vm.parseJsonBytes32(json, ".provenanceHash");
        require(keccak256(a.table) == a.provenanceHash, "provenance hash does not match the table");

        // forge's JSON paths have no wildcard, so the arrays are walked by index.
        uint256 count = _count(json, ".categories");
        require(count > 0, "no categories");
        a.categories = new Category[](count);
        for (uint256 i = 0; i < count; ++i) {
            string memory k = string(abi.encodePacked(".categories[", vm.toString(i), "]"));
            a.categories[i].name = vm.parseJsonString(json, string(abi.encodePacked(k, ".name")));
            a.categories[i].layers = vm.parseJsonStringArray(json, string(abi.encodePacked(k, ".layers")));
            a.categories[i].blob = vm.parseJsonBytes(json, string(abi.encodePacked(k, ".blob")));
        }
        require(a.table.length == a.rows * count, "table size does not match rows x categories");

        uint256 samples = _count(json, ".samples");
        a.sampleRows = new uint256[](samples);
        a.samplePixels = new bytes[](samples);
        for (uint256 i = 0; i < samples; ++i) {
            string memory k = string(abi.encodePacked(".samples[", vm.toString(i), "]"));
            a.sampleRows[i] = vm.parseJsonUint(json, string(abi.encodePacked(k, ".row")));
            a.samplePixels[i] = vm.parseJsonBytes(json, string(abi.encodePacked(k, ".pixels")));
        }
    }

    /// @notice The export plus the picture of every row, written by tools/art-check.mjs from the
    ///         token PNGs (`<export>.pixels.bin`). This is the input to the 555 of 555 check.
    function loadFull(string memory path, string memory pixelsPath) internal view returns (Art memory a) {
        a = load(path);
        a.fullPixels = vm.readFileBinary(pixelsPath);
        require(a.fullPixels.length == a.rows * 1024, "pixels file must hold rows x 1024 bytes");
    }

    function _count(string memory json, string memory arrayPath) private view returns (uint256 n) {
        while (vm.keyExistsJson(json, string(abi.encodePacked(arrayPath, "[", vm.toString(n), "]")))) ++n;
    }

    /// @notice Loads every category and the table into a renderer the caller owns.
    function loadInto(Art memory a, NightfallRenderer renderer) internal {
        for (uint256 i = 0; i < a.categories.length; ++i) {
            renderer.addCategory(a.categories[i].name, a.categories[i].blob, a.categories[i].layers);
        }
        renderer.setTable(a.table);
    }

    /// @notice Every exported trait the table never uses, as "Category / Trait". A 555 run
    ///         misses a rare trait about one time in ten, and the table is fixed before mint, so an
    ///         export with a missing trait is refused by name instead of minting a set without it.
    ///         A trait meant to have no share is removed in Trait Forge before exporting.
    function missingTraits(Art memory a) internal pure returns (string[] memory names) {
        uint256 n = a.categories.length;
        uint256 found;
        string[] memory buf = new string[](256 * n);
        for (uint256 c = 0; c < n; ++c) {
            uint256 layers = a.categories[c].layers.length;
            bool[] memory used = new bool[](layers);
            for (uint256 r = 0; r < a.rows; ++r) {
                uint256 v = uint8(a.table[r * n + c]);
                if (v != 0xFF && v < layers) used[v] = true;
            }
            for (uint256 l = 0; l < layers; ++l) {
                if (!used[l]) buf[found++] = string(abi.encodePacked(a.categories[c].name, " / ", a.categories[c].layers[l]));
            }
        }
        names = new string[](found);
        for (uint256 i = 0; i < found; ++i) names[i] = buf[i];
    }

    /// @notice True when a picture of every row is loaded, which is what the full check needs.
    function isFull(Art memory a) internal pure returns (bool) {
        return a.rows != 0 && a.fullPixels.length == a.rows * 1024;
    }

    /// @notice Renders every sample row through the renderer and compares it, byte for byte,
    ///         with the picture Trait Forge drew. Returns the rows that differ.
    function verify(Art memory a, NightfallRenderer renderer) internal view returns (uint256[] memory bad) {
        uint256 n = 0;
        if (isFull(a)) {
            uint256[] memory found = new uint256[](a.rows);
            bytes memory full = a.fullPixels;
            for (uint256 r = 0; r < a.rows; ++r) {
                bytes32 want;
                assembly ("memory-safe") {
                    want := keccak256(add(add(full, 32), mul(r, 1024)), 1024)
                }
                if (keccak256(renderer.pixels(r, 0)) != want) found[n++] = r;
            }
            bad = new uint256[](n);
            for (uint256 i = 0; i < n; ++i) bad[i] = found[i];
            return bad;
        }
        uint256[] memory found = new uint256[](a.sampleRows.length);
        for (uint256 i = 0; i < a.sampleRows.length; ++i) {
            bytes memory got = renderer.pixels(a.sampleRows[i], 0);
            if (keccak256(got) != keccak256(a.samplePixels[i])) found[n++] = a.sampleRows[i];
        }
        bad = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) bad[i] = found[i];
    }

    /// @notice How many rows `verify` compares: every row with a full load, else the samples.
    function checkedRows(Art memory a) internal pure returns (uint256) {
        return isFull(a) ? a.rows : a.sampleRows.length;
    }
}
