// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

/**
 * @title  PlaceholderArt
 * @notice Script-generated test layers for testnet and tests. Plain shapes on the 16 x 16 grid,
 *         nothing drawn by hand, nothing from the artist. They exist to prove the packer, the
 *         storage and the renderer, and they are what testnet shows. Never the real art.
 *
 *         Every builder returns a LayerSet blob (see lib/LayerSet.sol).
 */
library PlaceholderArt {
    uint256 internal constant PIXELS = 256;

    // ------------------------------------------------------------------------------------
    // Builders
    // ------------------------------------------------------------------------------------

    /// @notice Packs a colour table and layers into one blob.
    function layerSet(uint24[] memory colours, bytes[] memory layers) internal pure returns (bytes memory blob) {
        require(colours.length > 0 && colours.length < 256, "colours");
        blob = new bytes(1 + 3 * colours.length + PIXELS * layers.length);
        blob[0] = bytes1(uint8(colours.length));
        for (uint256 i = 0; i < colours.length; ++i) {
            blob[1 + 3 * i] = bytes1(uint8(colours[i] >> 16));
            blob[2 + 3 * i] = bytes1(uint8(colours[i] >> 8));
            blob[3 + 3 * i] = bytes1(uint8(colours[i]));
        }
        uint256 start = 1 + 3 * colours.length;
        for (uint256 l = 0; l < layers.length; ++l) {
            require(layers[l].length == PIXELS, "layer");
            for (uint256 p = 0; p < PIXELS; ++p) blob[start + l * PIXELS + p] = layers[l][p];
        }
    }

    function blank() internal pure returns (bytes memory) {
        return new bytes(PIXELS);
    }

    /// @notice Fills the inclusive rectangle with a colour index.
    function rect(bytes memory px, uint256 x0, uint256 y0, uint256 x1, uint256 y1, uint8 value)
        internal
        pure
        returns (bytes memory)
    {
        for (uint256 y = y0; y <= y1; ++y) {
            for (uint256 x = x0; x <= x1; ++x) px[y * 16 + x] = bytes1(value);
        }
        return px;
    }

    // ------------------------------------------------------------------------------------
    // The placeholder set: seven Genesis categories in the spec's stack order.
    // ------------------------------------------------------------------------------------

    function categoryNames() internal pure returns (string[] memory names) {
        names = new string[](7);
        names[0] = "Background";
        names[1] = "Body";
        names[2] = "Clothing";
        names[3] = "Hair";
        names[4] = "Eyes/Eyewear";
        names[5] = "Headwear";
        names[6] = "Face Accessory";
    }

    /// @notice Layer names per category, matching `category(i)`.
    function layerNames(uint256 index) internal pure returns (string[] memory names) {
        if (index == 0) {
            names = new string[](3);
            names[0] = "Test Night";
            names[1] = "Test Dusk";
            names[2] = "Test Neon";
        } else if (index == 1) {
            names = new string[](2);
            names[0] = "Test Body A";
            names[1] = "Test Body B";
        } else if (index == 2) {
            names = new string[](3);
            names[0] = "Test Jacket";
            names[1] = "Test Coat";
            names[2] = "Test Vest";
        } else if (index == 3) {
            names = new string[](3);
            names[0] = "Test Short";
            names[1] = "Test Long";
            names[2] = "Test Mohawk";
        } else if (index == 4) {
            names = new string[](2);
            names[0] = "Test Eyes";
            names[1] = "Test Shades";
        } else if (index == 5) {
            names = new string[](2);
            names[0] = "Test Cap";
            names[1] = "Test Hood";
        } else {
            names = new string[](2);
            names[0] = "Test Scar";
            names[1] = "Test Mask";
        }
    }

    /// @notice The blob for a category.
    function category(uint256 index) internal pure returns (bytes memory) {
        if (index == 0) return background();
        if (index == 1) return body();
        if (index == 2) return clothing();
        if (index == 3) return hair();
        if (index == 4) return eyes();
        if (index == 5) return headwear();
        return faceAccessory();
    }

    function background() internal pure returns (bytes memory) {
        uint24[] memory c = new uint24[](3);
        c[0] = 0x0b0b16;
        c[1] = 0x2a1440;
        c[2] = 0x083a4a;
        bytes[] memory l = new bytes[](3);
        l[0] = rect(blank(), 0, 0, 15, 15, 1);
        l[1] = rect(blank(), 0, 0, 15, 15, 2);
        l[2] = rect(blank(), 0, 0, 15, 15, 3);
        return layerSet(c, l);
    }

    function body() internal pure returns (bytes memory) {
        uint24[] memory c = new uint24[](2);
        c[0] = 0xe0b090;
        c[1] = 0x8a5a3a;
        bytes[] memory l = new bytes[](2);
        l[0] = rect(rect(blank(), 5, 4, 10, 9, 1), 6, 10, 9, 15, 1); // head and neck/torso
        l[1] = rect(rect(blank(), 5, 4, 10, 9, 2), 6, 10, 9, 15, 2);
        return layerSet(c, l);
    }

    function clothing() internal pure returns (bytes memory) {
        uint24[] memory c = new uint24[](3);
        c[0] = 0x1f1f2e;
        c[1] = 0x7a1030;
        c[2] = 0x2de2ff;
        bytes[] memory l = new bytes[](3);
        l[0] = rect(blank(), 4, 11, 11, 15, 1);
        l[1] = rect(blank(), 3, 11, 12, 15, 2);
        l[2] = rect(blank(), 5, 12, 10, 15, 3);
        return layerSet(c, l);
    }

    function hair() internal pure returns (bytes memory) {
        uint24[] memory c = new uint24[](3);
        c[0] = 0x111111;
        c[1] = 0xff2d95;
        c[2] = 0xf5e663;
        bytes[] memory l = new bytes[](3);
        l[0] = rect(blank(), 5, 3, 10, 4, 1);
        l[1] = rect(rect(blank(), 5, 3, 10, 4, 2), 4, 5, 4, 9, 2);
        l[2] = rect(blank(), 7, 1, 8, 4, 3);
        return layerSet(c, l);
    }

    function eyes() internal pure returns (bytes memory) {
        uint24[] memory c = new uint24[](2);
        c[0] = 0xffffff;
        c[1] = 0x101018;
        bytes[] memory l = new bytes[](2);
        l[0] = rect(rect(blank(), 6, 6, 6, 6, 1), 9, 6, 9, 6, 1);
        l[1] = rect(blank(), 5, 6, 10, 7, 2);
        return layerSet(c, l);
    }

    function headwear() internal pure returns (bytes memory) {
        uint24[] memory c = new uint24[](2);
        c[0] = 0x2f7a3a;
        c[1] = 0x3a3a52;
        bytes[] memory l = new bytes[](2);
        l[0] = rect(rect(blank(), 4, 2, 11, 3, 1), 4, 4, 12, 4, 1); // cap with a peak
        l[1] = rect(rect(blank(), 4, 1, 11, 4, 2), 4, 5, 4, 9, 2); // hood
        return layerSet(c, l);
    }

    /// @notice A test cosmetic for the Headwear category: one gold crown layer, appended with
    ///         `addLayers` to prove upgrades. Never the real art.
    function cosmeticCrown() internal pure returns (bytes memory) {
        uint24[] memory c = new uint24[](2);
        c[0] = 0xffd23f;
        c[1] = 0xff2d95;
        bytes[] memory l = new bytes[](1);
        l[0] = rect(rect(rect(rect(blank(), 4, 3, 11, 4, 1), 4, 1, 4, 2, 1), 7, 0, 8, 2, 1), 11, 1, 11, 2, 1);
        l[0][3 * 16 + 7] = bytes1(uint8(2)); // one pink jewel
        return layerSet(c, l);
    }

    function faceAccessory() internal pure returns (bytes memory) {
        uint24[] memory c = new uint24[](2);
        c[0] = 0xc0392b;
        c[1] = 0x555566;
        bytes[] memory l = new bytes[](2);
        l[0] = rect(blank(), 10, 7, 10, 8, 1);
        l[1] = rect(blank(), 5, 8, 10, 9, 2);
        return layerSet(c, l);
    }

    /// @notice A single background layer using 64 colours, to show the renderer has no palette
    ///         limit. Every row of the 16 x 16 grid gets four colours across it.
    function gradientBackground() internal pure returns (bytes memory) {
        uint24[] memory c = new uint24[](64);
        for (uint256 i = 0; i < 64; ++i) c[i] = uint24((i * 4) << 16) | uint24((255 - i * 4) << 8) | uint24(i * 2 + 60);
        bytes memory px = blank();
        for (uint256 p = 0; p < PIXELS; ++p) px[p] = bytes1(uint8(p / 4 + 1));
        bytes[] memory l = new bytes[](1);
        l[0] = px;
        return layerSet(c, l);
    }

    /// @notice Layer counts per placeholder category, for table generation.
    function layersPer() internal pure returns (uint256[] memory counts) {
        counts = new uint256[](7);
        for (uint256 i = 0; i < 7; ++i) counts[i] = layerNames(i).length;
    }

    /// @notice A deterministic trait table: one byte per category per row. Background, Body,
    ///         Clothing and Eyes always present; Hair, Headwear and Face Accessory sometimes
    ///         absent (0xFF). Headwear suppresses Hair, per the spec's clash rule.
    function table(uint256 rows, bytes32 seed) internal pure returns (bytes memory t) {
        uint256[] memory counts = layersPer();
        uint256 categories = counts.length;
        t = new bytes(rows * categories);
        for (uint256 r = 0; r < rows; ++r) {
            bytes32 h = keccak256(abi.encodePacked(seed, r));
            for (uint256 c = 0; c < categories; ++c) {
                uint256 roll = uint8(h[c]);
                uint256 pick = uint8(h[c + 8]) % counts[c];
                bool present = true;
                if (c == 5) present = roll < 96; // headwear on about a third
                if (c == 6) present = roll < 128; // face accessory on half
                if (c == 3 && uint8(t[r * categories + 5]) != 0xFF) present = false; // hair under headwear
                t[r * categories + c] = present ? bytes1(uint8(pick)) : bytes1(0xFF);
            }
        }
    }
}
