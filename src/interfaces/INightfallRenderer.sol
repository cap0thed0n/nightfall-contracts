// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

/// @notice What a Nightfall token contract asks its renderer for. The renderer is read-only for
///         tokens and swappable: the token contract holds its address and the owner can point at
///         a new one.
interface INightfallRenderer {
    /// @param tokenId  The token being rendered.
    /// @param revealed False until the collection's reveal; the renderer returns the pre-reveal
    ///                 image and no traits.
    /// @param offset   The reveal offset. The trait row is (tokenId + offset) mod rowCount.
    /// @param tier     0 for no border (Genesis). Operators pass their on-chain tier.
    /// @param traits   The token's applied cosmetics: three bytes per entry, a category then a
    ///                 16-bit layer index, each replacing that category's layer from the row.
    /// @return A data: URI carrying the JSON metadata with the image inside.
    function tokenURI(uint256 tokenId, bool revealed, uint256 offset, uint8 tier, bytes calldata traits) external view returns (string memory);

    /// @notice How many categories the art has.
    function categoryCount() external view returns (uint256);

    /// @notice How many layers a category holds, base and cosmetic.
    function layerCount(uint256 category) external view returns (uint256);

    /// @notice How many tokens may ever wear a cosmetic, set when it was uploaded. Zero for a
    ///         base (mint) layer, which is never applied as a cosmetic.
    function cosmeticCap(uint256 category, uint256 layer) external view returns (uint256);
}
