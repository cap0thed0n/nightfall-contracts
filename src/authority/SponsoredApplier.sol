// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Ownable } from "openzeppelin-contracts/access/Ownable.sol";
import { EIP712 } from "openzeppelin-contracts/utils/cryptography/EIP712.sol";
import { SignatureChecker } from "openzeppelin-contracts/utils/cryptography/SignatureChecker.sol";

/// @notice The token's sponsored entry point.
interface ISponsoredToken {
    function applyTraitFor(address player, uint256 tokenId, uint256 category, uint256 layer, bytes calldata proof) external;
}

/**
 * @title  SponsoredApplier
 * @notice The path where the project pays the gas for applying a cosmetic. Built, and off by
 *         default twice over: the token only takes `applyTraitFor` from its `sponsor`, which is
 *         zero until the owner sets it to this contract, and this contract refuses everything
 *         until its owner calls `setEnabled(true)`.
 *
 *         The player still decides. They sign an EIP-712 request naming the token, the cosmetic,
 *         the exact voucher (by its hash) and a deadline; nothing is sent from their wallet and
 *         they pay nothing. A relayer the project runs submits the request with `submit` and pays
 *         the gas. Every check the token makes on `applyTrait` still runs, with the player in
 *         place of the sender: they must hold the token, the cosmetic must be under its cap,
 *         and the voucher must be the game's, for this wallet, token and cosmetic, unspent.
 *
 *         A request works once: its voucher is spent by the authority when it goes through, so
 *         the same request replayed is refused there. Smart-contract wallets sign through
 *         ERC-1271.
 */
contract SponsoredApplier is Ownable, EIP712 {
    /// @notice What the player signs.
    struct Request {
        address player;
        uint256 tokenId;
        uint256 category;
        uint256 layer;
        bytes32 proofHash;
        uint256 deadline;
    }

    bytes32 public constant REQUEST_TYPEHASH =
        keccak256("Request(address player,uint256 tokenId,uint256 category,uint256 layer,bytes32 proofHash,uint256 deadline)");

    /// @notice The token whose cosmetics this contract applies.
    ISponsoredToken public immutable token;
    /// @notice Off until the owner turns it on.
    bool public enabled;
    /// @notice The wallets allowed to submit, the project's relayers. None until the owner adds one.
    mapping(address => bool) public relayer;

    event EnabledSet(bool enabled);
    event RelayerSet(address indexed relayer, bool allowed);
    event SponsoredApply(address indexed player, uint256 indexed tokenId, uint256 category, uint256 layer, address indexed relayer);

    error SponsoringOff();
    error NotRelayer(address sender);
    error RequestExpired(uint256 deadline);
    error NotSignedByPlayer(address player);

    constructor(address token_) EIP712("Nightfall Sponsored Apply", "1") {
        token = ISponsoredToken(token_);
    }

    function setEnabled(bool on) external onlyOwner {
        enabled = on;
        emit EnabledSet(on);
    }

    function setRelayer(address who, bool allowed) external onlyOwner {
        relayer[who] = allowed;
        emit RelayerSet(who, allowed);
    }

    /// @notice The EIP-712 digest the player signs, for the client and tests.
    function requestDigest(Request memory r) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(REQUEST_TYPEHASH, r.player, r.tokenId, r.category, r.layer, r.proofHash, r.deadline)));
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice A relayer submits the player's signed request with the game's voucher; this
    ///         contract checks the player's signature and applies the cosmetic for them.
    function submit(Request calldata r, bytes calldata proof, bytes calldata playerSignature) external {
        if (!enabled) revert SponsoringOff();
        if (!relayer[msg.sender]) revert NotRelayer(msg.sender);
        if (block.timestamp > r.deadline) revert RequestExpired(r.deadline);
        // The request names this exact voucher, so a relayer cannot swap in another.
        Request memory checked = Request(r.player, r.tokenId, r.category, r.layer, keccak256(proof), r.deadline);
        if (!SignatureChecker.isValidSignatureNow(r.player, requestDigest(checked), playerSignature)) revert NotSignedByPlayer(r.player);
        token.applyTraitFor(r.player, r.tokenId, r.category, r.layer, proof);
        emit SponsoredApply(r.player, r.tokenId, r.category, r.layer, msg.sender);
    }
}
