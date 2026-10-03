// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

/// @notice Decides whether a player may apply a cosmetic trait to a token. The token contract
///         asks it on every upgrade and refuses unless it returns true. How ownership of the
///         cosmetic is proved lives here, not in the token, so the method can change without
///         redeploying the collection. An authority must accept calls only from the token.
interface ITraitAuthority {
    /// @param player   The wallet applying the trait; the token has already checked it holds tokenId.
    /// @param tokenId  The token being upgraded.
    /// @param category The category the trait replaces.
    /// @param layer    The trait's layer index in that category.
    /// @param proof    Whatever the authority needs (a signature, a Merkle proof), passed through.
    function authorize(address player, uint256 tokenId, uint256 category, uint256 layer, bytes calldata proof) external returns (bool);
}
