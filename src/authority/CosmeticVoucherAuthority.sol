// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Ownable } from "openzeppelin-contracts/access/Ownable.sol";
import { ECDSA } from "openzeppelin-contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "openzeppelin-contracts/utils/cryptography/EIP712.sol";
import { ITraitAuthority } from "../interfaces/ITraitAuthority.sol";

/// @notice What the authority reads from the token to keep its key separate from the token's.
interface ITokenKeys {
    function operator() external view returns (address);
    function owner() external view returns (address);
}

/**
 * @title  CosmeticVoucherAuthority
 * @notice How the token checks a player owns the cosmetic they apply: a voucher signed by the
 *         game with a dedicated cosmetics key. The voucher names the wallet, the token, the
 *         cosmetic (category and trait), a one-time id and an expiry, as EIP-712 typed data, so
 *         a wallet can show the fields in plain words. The player submits it with
 *         `applyTrait` and pays the gas; the token hands it here as the proof.
 *
 *         The owner can swap the signing key at any moment. Only the current key is ever
 *         accepted, so a swap invalidates every unused voucher the old key signed. The key must
 *         be its own: never the token's operator (the lock key), the token's owner or this
 *         contract's owner.
 */
contract CosmeticVoucherAuthority is ITraitAuthority, Ownable, EIP712 {
    /// @notice The voucher the game signs.
    struct Voucher {
        address player;
        uint256 tokenId;
        uint256 category;
        uint256 layer;
        uint256 voucherId;
        uint256 expiresAt;
    }

    bytes32 public constant VOUCHER_TYPEHASH =
        keccak256("Voucher(address player,uint256 tokenId,uint256 category,uint256 layer,uint256 voucherId,uint256 expiresAt)");

    /// @notice The token contract whose upgrades this authority decides.
    address public immutable token;
    /// @notice The game's cosmetics signing key. Only vouchers it signed are accepted.
    address public signer;
    /// @notice Voucher ids already spent. An id works once, whoever it was for.
    mapping(uint256 => bool) public used;

    event SignerChanged(address indexed oldSigner, address indexed newSigner);
    event VoucherSpent(uint256 indexed voucherId, address indexed player, uint256 indexed tokenId, uint256 category, uint256 layer);

    error OnlyToken();
    error ZeroSigner();
    error SignerNotDedicated(address signer);
    error VoucherExpired(uint256 voucherId, uint256 expiresAt);
    error VoucherAlreadyUsed(uint256 voucherId);
    error VoucherForAnotherWallet(address voucherPlayer, address player);
    error VoucherForAnotherToken(uint256 voucherTokenId, uint256 tokenId);
    error VoucherForAnotherCosmetic(uint256 voucherCategory, uint256 voucherLayer, uint256 category, uint256 layer);
    error NotSignedByCosmeticsKey(address recovered);

    constructor(address token_, address signer_) EIP712("Nightfall Cosmetics", "1") {
        token = token_;
        _setSigner(signer_);
    }

    /// @notice Swaps the cosmetics signing key, at once. Vouchers the old key signed stop working.
    function setSigner(address newSigner) external onlyOwner {
        _setSigner(newSigner);
    }

    function _setSigner(address newSigner) internal {
        if (newSigner == address(0)) revert ZeroSigner();
        _requireDedicated(newSigner);
        emit SignerChanged(signer, newSigner);
        signer = newSigner;
    }

    /// @dev The cosmetics key is nobody else's key.
    function _requireDedicated(address key) internal view {
        if (key == owner() || key == ITokenKeys(token).operator() || key == ITokenKeys(token).owner()) revert SignerNotDedicated(key);
    }

    /// @notice The EIP-712 digest the game signs for a voucher, for off-chain tooling and tests.
    function voucherDigest(Voucher memory v) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(VOUCHER_TYPEHASH, v.player, v.tokenId, v.category, v.layer, v.voucherId, v.expiresAt)));
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Called by the token on `applyTrait`. `proof` is abi.encode(Voucher, signature).
    ///         Reverts with the reason when the voucher does not fit; spends it when it does.
    function authorize(address player, uint256 tokenId, uint256 category, uint256 layer, bytes calldata proof) external returns (bool) {
        if (msg.sender != token) revert OnlyToken();
        (Voucher memory v, bytes memory signature) = abi.decode(proof, (Voucher, bytes));
        if (block.timestamp > v.expiresAt) revert VoucherExpired(v.voucherId, v.expiresAt);
        if (used[v.voucherId]) revert VoucherAlreadyUsed(v.voucherId);
        if (v.player != player) revert VoucherForAnotherWallet(v.player, player);
        if (v.tokenId != tokenId) revert VoucherForAnotherToken(v.tokenId, tokenId);
        if (v.category != category || v.layer != layer) revert VoucherForAnotherCosmetic(v.category, v.layer, category, layer);
        address current = signer;
        // If the token's operator or owner has since become the cosmetics key, nothing it signs counts.
        _requireDedicated(current);
        (address recovered, ECDSA.RecoverError err) = ECDSA.tryRecover(voucherDigest(v), signature);
        if (err != ECDSA.RecoverError.NoError || recovered != current) revert NotSignedByCosmeticsKey(recovered);
        used[v.voucherId] = true;
        emit VoucherSpent(v.voucherId, player, tokenId, category, layer);
        return true;
    }
}
