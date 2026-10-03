// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

/// @notice The on-chain byte layout of one category's art, stored as a single SSTORE2 blob.
///
///         byte 0            colour count c (1..255)
///         bytes 1 .. 3c     the colour table, RGB, three bytes per colour
///         then k * 256      k layers of 16 x 16 pixels, one byte each, row-major:
///                           0 is transparent, 1..c indexes the colour table
///
///         There is no palette limit beyond the byte: a layer set carries whatever colours its
///         art uses, and 256 pixels can never need more than 255 of them.
library LayerSet {
    uint256 internal constant PIXELS = 256;
    uint256 internal constant SIDE = 16;

    error EmptyLayerSet();
    error BadColourCount(uint256 count);
    error MalformedLayerSet(uint256 length);
    error PixelOutOfPalette(uint256 layer, uint256 pixel, uint256 value, uint256 colours);

    function colourCount(bytes memory blob) internal pure returns (uint256) {
        if (blob.length == 0) revert EmptyLayerSet();
        return uint8(blob[0]);
    }

    function pixelsOffset(uint256 colours) internal pure returns (uint256) {
        return 1 + 3 * colours;
    }

    function layerCount(bytes memory blob) internal pure returns (uint256) {
        uint256 colours = colourCount(blob);
        uint256 start = pixelsOffset(colours);
        if (blob.length < start) revert MalformedLayerSet(blob.length);
        return (blob.length - start) / PIXELS;
    }

    /// @notice Refuses a blob that is not exactly a colour table plus whole layers whose pixels
    ///         all index the table. Called once, when the art is loaded.
    function validate(bytes memory blob) internal pure {
        uint256 colours = colourCount(blob);
        if (colours == 0) revert BadColourCount(colours);
        uint256 start = pixelsOffset(colours);
        if (blob.length <= start || (blob.length - start) % PIXELS != 0) revert MalformedLayerSet(blob.length);
        uint256 layers = (blob.length - start) / PIXELS;
        for (uint256 l = 0; l < layers; ++l) {
            uint256 base = start + l * PIXELS;
            for (uint256 p = 0; p < PIXELS; ++p) {
                uint256 v = uint8(blob[base + p]);
                if (v > colours) revert PixelOutOfPalette(l, p, v, colours);
            }
        }
    }

    function colour(bytes memory blob, uint256 index) internal pure returns (uint24) {
        // index is 1-based, as in the pixels.
        uint256 at = 1 + 3 * (index - 1);
        return (uint24(uint8(blob[at])) << 16) | (uint24(uint8(blob[at + 1])) << 8) | uint24(uint8(blob[at + 2]));
    }

    function pixel(bytes memory blob, uint256 layer, uint256 p) internal pure returns (uint256) {
        return uint8(blob[pixelsOffset(colourCount(blob)) + layer * PIXELS + p]);
    }
}
