// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { ERC721SeaDrop } from "seadrop/ERC721SeaDrop.sol";
import { ERC721ContractMetadata } from "seadrop/ERC721ContractMetadata.sol";
import { ISeaDropTokenContractMetadata } from "seadrop/interfaces/ISeaDropTokenContractMetadata.sol";
import { ERC721AConduitPreapproved } from "seadrop/lib/ERC721AConduitPreapproved.sol";
import { ERC721A } from "ERC721A/ERC721A.sol";
import { IERC721A } from "ERC721A/IERC721A.sol";
import { ERC721AQueryable } from "ERC721A/extensions/ERC721AQueryable.sol";
import { INightfallRenderer } from "./interfaces/INightfallRenderer.sol";
import { ITraitAuthority } from "./interfaces/ITraitAuthority.sol";

/**
 * @title  NightfallGenesis
 * @notice The Genesis collection of Nightfall City. An ERC721SeaDrop token, so OpenSea's drop
 *         system mints it and its creator-token transfer validator enforces royalties, with three
 *         additions that touch no SeaDrop function:
 *
 *         - The art is on chain. `tokenURI` asks a swappable renderer instead of a base URI.
 *         - Characters lock while they work. A game operator wallet sets expiring locks; a locked
 *           token cannot be transferred, so a listing cannot fill. The operator can do nothing
 *           else, and the owner can replace it at any time.
 *         - The reveal is commit-reveal. The owner commits to a secret before the first mint.
 *           Minting ends for good at sell-out or when the owner closes it, and at that moment
 *           the contract sets the target block itself, a fixed margin ahead, so nobody can aim
 *           it. Once the target passes, anyone captures its hash, which fixes the outcome for
 *           good; the secret mixed with that hash gives the offset into the committed trait
 *           table, and the reveal can then happen at any time. Nobody can reroll.
 *         - Revealed characters can be upgraded. A holder applies a cosmetic trait the game says
 *           they own; it replaces that category's trait in the token's image and metadata. A
 *           swappable authority contract decides what counts as proof of ownership.
 *
 *         Supply is `maxSupply` alone. Every reserve is a SeaDrop stage, not contract logic.
 */
contract NightfallGenesis is ERC721SeaDrop, ERC721AQueryable {
    // ---------------------------------------------------------------------------------------
    // Supply
    // ---------------------------------------------------------------------------------------

    /// @notice SeaDrop's setMaxSupply with one more rule: it refuses every change, up, down or
    ///         to the same value, once minting has started. Before the first mint it behaves as
    ///         SeaDrop's does (owner or self, at most uint64). The vendored SeaDrop declares the
    ///         function virtual for exactly this override; see lib/seadrop/VENDORED.md.
    function setMaxSupply(uint256 newMaxSupply) external virtual override(ERC721ContractMetadata, ISeaDropTokenContractMetadata) {
        _onlyOwnerOrSelf();
        if (_totalMinted() != 0) revert SupplyFixedAfterMintStarted(_maxSupply);
        if (newMaxSupply > 2 ** 64 - 1) revert CannotExceedMaxSupplyOfUint64(newMaxSupply);
        _maxSupply = newMaxSupply;
        emit MaxSupplyUpdated(newMaxSupply);
    }

    // ---------------------------------------------------------------------------------------
    // Renderer
    // ---------------------------------------------------------------------------------------

    INightfallRenderer public renderer;

    event RendererUpdated(address indexed oldRenderer, address indexed newRenderer);

    // ---------------------------------------------------------------------------------------
    // Trait upgrades
    // ---------------------------------------------------------------------------------------

    /// @notice Decides whether a holder may apply a cosmetic. Zero until the owner sets one,
    ///         which leaves upgrades off.
    address public traitAuthority;
    /// @dev Each token's applied cosmetics, three bytes per category it changes (category,
    ///      16-bit layer index), handed to the renderer with every tokenURI.
    mapping(uint256 => bytes) internal _traits;
    /// @notice How many times each cosmetic has been applied across every token, keyed
    ///         category << 16 | layer. Never goes down: replacing a cosmetic does not free its slot.
    mapping(uint256 => uint256) public cosmeticApplied;
    /// @notice The one contract that may apply a cosmetic on a holder's behalf, so the project
    ///         pays the gas (`applyTraitFor`). Zero, the default, turns that path off.
    address public sponsor;

    event TraitAuthorityUpdated(address indexed oldAuthority, address indexed newAuthority);
    event TraitApplied(uint256 indexed tokenId, uint256 indexed category, uint256 layer, address indexed player);
    event SponsorUpdated(address indexed oldSponsor, address indexed newSponsor);
    /// @dev EIP-4906: marketplaces refresh one token's metadata on this.
    event MetadataUpdate(uint256 _tokenId);

    error UpgradesOff();
    error NotRevealed();
    error NotTokenHolder(uint256 tokenId);
    error NoSuchTrait(uint256 category, uint256 layer);
    error UpgradeNotAuthorized();
    error NotACosmetic(uint256 category, uint256 layer);
    error CosmeticSoldOut(uint256 category, uint256 layer, uint256 cap);
    error NotSponsor();

    // ---------------------------------------------------------------------------------------
    // Lock
    // ---------------------------------------------------------------------------------------

    /// @notice The game operator wallet. Sets locks and nothing else.
    address public operator;
    /// @notice The longest a single lock call may reach into the future. A safety ceiling.
    uint64 public maxLockSeconds;
    mapping(uint256 => uint64) internal _lockedUntil;

    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event MaxLockSecondsUpdated(uint64 oldMax, uint64 newMax);
    event Locked(uint256 indexed tokenId, uint64 until);

    error NotOperator();
    error LockTooLong(uint256 tokenId, uint64 until, uint64 latestAllowed);
    error LockArraysMismatch(uint256 tokenIds, uint256 untils);
    error TokenLocked(uint256 tokenId, uint64 until);
    error ZeroMaxLock();

    // ---------------------------------------------------------------------------------------
    // Supply
    // ---------------------------------------------------------------------------------------

    /// @notice The supply is fixed for good once the first token exists.
    error SupplyFixedAfterMintStarted(uint256 maxSupply);

    // ---------------------------------------------------------------------------------------
    // Reveal
    // ---------------------------------------------------------------------------------------

    /// @notice keccak256 of the reveal secret, committed before the first mint.
    bytes32 public revealCommitment;
    /// @notice The block whose hash is the entropy. Zero while minting is open; set by the
    ///         contract to REVEAL_DELAY_BLOCKS after the block where minting closed.
    uint256 public revealTargetBlock;
    /// @notice True once minting has ended, at sell-out or by `closeMint`. Nothing mints after.
    bool public mintClosed;
    /// @notice The margin between the close and the target block, in L1 blocks (Nitro's
    ///         block.number). About six minutes: well past any jump in Nitro's L1 block
    ///         estimate, so the target's hash cannot exist when the close is sent.
    uint256 public constant REVEAL_DELAY_BLOCKS = 30;
    /// @notice The captured block hash. Zero until someone captures it.
    bytes32 public revealEntropy;
    /// @notice The block whose hash was captured: the target, or a later stride if the target
    ///         was missed.
    uint256 public revealEntropyBlock;
    bool public revealed;
    uint256 public revealOffset;

    /// @dev A block hash is readable for 256 blocks. If nobody captures the target's hash in
    ///      that time, the candidate moves forward by exactly one stride, so at any moment there
    ///      is exactly one readable candidate and nobody can pick between two.
    uint256 public constant ENTROPY_STRIDE = 256;

    event RevealCommitted(bytes32 commitment);
    event MintClosed(uint256 minted, uint256 targetBlock, bool soldOut);
    event EntropyCaptured(uint256 indexed blockNumber, bytes32 blockHash, bool missedTarget);
    event Revealed(bytes32 secret, bytes32 entropy, uint256 offset);

    error AlreadyRevealed();
    error RevealNotCommitted();
    error CommitAfterMintStarted();
    error ZeroCommitment();
    error MintIsClosed();
    error MintStillOpen();
    error TargetBlockNotReached(uint256 targetBlock, uint256 currentBlock);
    error EntropyAlreadyCaptured(uint256 blockNumber);
    error EntropyNotCaptured();
    error WrongSecret();
    error BlockHashUnavailable(uint256 blockNumber);

    constructor(string memory name, string memory symbol, address[] memory allowedSeaDrop)
        ERC721SeaDrop(name, symbol, allowedSeaDrop)
    {}

    // ---------------------------------------------------------------------------------------
    // Renderer
    // ---------------------------------------------------------------------------------------

    /// @notice Points the collection at a renderer. Owner only.
    function setRenderer(address newRenderer) external onlyOwner {
        address old = address(renderer);
        renderer = INightfallRenderer(newRenderer);
        emit RendererUpdated(old, newRenderer);
        if (totalSupply() != 0) emit BatchMetadataUpdate(_startTokenId(), _nextTokenId() - 1);
    }

    /// @notice On-chain metadata from the renderer. Falls back to SeaDrop's base URI behaviour
    ///         while no renderer is set.
    function tokenURI(uint256 tokenId) public view virtual override(ERC721A, ERC721SeaDrop, IERC721A) returns (string memory) {
        if (!_exists(tokenId)) revert URIQueryForNonexistentToken();
        if (address(renderer) == address(0)) return ERC721SeaDrop.tokenURI(tokenId);
        return renderer.tokenURI(tokenId, revealed, revealOffset, 0, _traits[tokenId]);
    }

    // ---------------------------------------------------------------------------------------
    // Trait upgrades
    // ---------------------------------------------------------------------------------------

    /// @notice Sets the contract that decides whether a holder owns a cosmetic. Owner only;
    ///         zero turns upgrades off.
    function setTraitAuthority(address newAuthority) external onlyOwner {
        emit TraitAuthorityUpdated(traitAuthority, newAuthority);
        traitAuthority = newAuthority;
    }

    /// @notice Sets the contract that may apply cosmetics on holders' behalf. Owner only; zero
    ///         (the default) turns the sponsored path off.
    function setSponsor(address newSponsor) external onlyOwner {
        emit SponsorUpdated(sponsor, newSponsor);
        sponsor = newSponsor;
    }

    /// @notice The holder of a revealed token applies a cosmetic trait: `layer` in `category`
    ///         replaces whatever that category showed, in the image and the metadata. The
    ///         holder signs and pays for it. The authority must confirm they own the cosmetic.
    function applyTrait(uint256 tokenId, uint256 category, uint256 layer, bytes calldata proof) external {
        _applyTrait(msg.sender, tokenId, category, layer, proof);
    }

    /// @notice The same for `player`, sent by the sponsor contract, which has checked the
    ///         player's own signature and pays the gas. Every check is the same as `applyTrait`'s.
    function applyTraitFor(address player, uint256 tokenId, uint256 category, uint256 layer, bytes calldata proof) external {
        if (msg.sender != sponsor || msg.sender == address(0)) revert NotSponsor();
        _applyTrait(player, tokenId, category, layer, proof);
    }

    function _applyTrait(address player, uint256 tokenId, uint256 category, uint256 layer, bytes calldata proof) internal {
        address authority = traitAuthority;
        if (authority == address(0)) revert UpgradesOff();
        if (!revealed) revert NotRevealed();
        if (ownerOf(tokenId) != player) revert NotTokenHolder(tokenId);
        if (category >= renderer.categoryCount() || layer >= renderer.layerCount(category) || category > 255 || layer > 0xFFFF) {
            revert NoSuchTrait(category, layer);
        }
        // The supply cap, set when the cosmetic was uploaded. A base layer has none and is never
        // applied as a cosmetic.
        uint256 cap = renderer.cosmeticCap(category, layer);
        if (cap == 0) revert NotACosmetic(category, layer);
        uint256 key = (category << 16) | layer;
        uint256 applied = cosmeticApplied[key] + 1;
        if (applied > cap) revert CosmeticSoldOut(category, layer, cap);
        cosmeticApplied[key] = applied;
        if (!ITraitAuthority(authority).authorize(player, tokenId, category, layer, proof)) revert UpgradeNotAuthorized();

        bytes memory t = _traits[tokenId];
        uint256 at = t.length;
        for (uint256 i = 0; i < t.length; i += 3) {
            if (uint8(t[i]) == category) {
                at = i;
                break;
            }
        }
        if (at == t.length) t = bytes.concat(t, new bytes(3));
        t[at] = bytes1(uint8(category));
        t[at + 1] = bytes1(uint8(layer >> 8));
        t[at + 2] = bytes1(uint8(layer));
        _traits[tokenId] = t;
        emit TraitApplied(tokenId, category, layer, player);
        emit MetadataUpdate(tokenId);
    }

    /// @notice A token's applied cosmetics, as the renderer receives them.
    function traitsOf(uint256 tokenId) external view returns (bytes memory) {
        return _traits[tokenId];
    }

    // ---------------------------------------------------------------------------------------
    // Lock
    // ---------------------------------------------------------------------------------------

    function setOperator(address newOperator) external onlyOwner {
        address old = operator;
        operator = newOperator;
        emit OperatorUpdated(old, newOperator);
    }

    function setMaxLockSeconds(uint64 newMax) external onlyOwner {
        if (newMax == 0) revert ZeroMaxLock();
        uint64 old = maxLockSeconds;
        maxLockSeconds = newMax;
        emit MaxLockSecondsUpdated(old, newMax);
    }

    /// @notice Locks each token until its own timestamp. Operator only. A timestamp at or before
    ///         now lifts the lock; one past now plus `maxLockSeconds` is refused. Refused for a
    ///         token that does not exist.
    function lockUntil(uint256[] calldata tokenIds, uint64[] calldata untils) external {
        if (msg.sender != operator) revert NotOperator();
        if (tokenIds.length != untils.length) revert LockArraysMismatch(tokenIds.length, untils.length);
        uint64 latest = uint64(block.timestamp) + maxLockSeconds;
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            uint64 until = untils[i];
            if (!_exists(id)) revert URIQueryForNonexistentToken();
            if (until > latest) revert LockTooLong(id, until, latest);
            _lockedUntil[id] = until;
            emit Locked(id, until);
        }
    }

    function lockedUntil(uint256 tokenId) external view returns (uint64) {
        return _lockedUntil[tokenId];
    }

    function isLocked(uint256 tokenId) public view returns (bool) {
        return _lockedUntil[tokenId] > block.timestamp;
    }

    /// @dev SeaDrop's hook runs the transfer validator first; then a locked token refuses to
    ///      move. A mint needs the reveal committed and minting still open; the mint that
    ///      reaches maxSupply closes minting itself. No stage can mint after the close.
    function _beforeTokenTransfers(address from, address to, uint256 startTokenId, uint256 quantity)
        internal
        virtual
        override(ERC721A, ERC721ContractMetadata)
    {
        ERC721ContractMetadata._beforeTokenTransfers(from, to, startTokenId, quantity);
        if (from == address(0)) {
            if (mintClosed) revert MintIsClosed();
            if (revealCommitment == bytes32(0)) revert RevealNotCommitted();
            if (_totalMinted() + quantity >= maxSupply()) _closeMint(true, _totalMinted() + quantity);
        } else {
            for (uint256 id = startTokenId; id < startTokenId + quantity; ++id) {
                uint64 until = _lockedUntil[id];
                if (until > block.timestamp) revert TokenLocked(id, until);
            }
        }
    }

    // ---------------------------------------------------------------------------------------
    // Reveal
    // ---------------------------------------------------------------------------------------

    /// @notice Owner, before the first mint, which needs it. Commits to keccak256(secret) and
    ///         nothing else: the target block is set when minting closes.
    function commitReveal(bytes32 commitment) external onlyOwner {
        if (_totalMinted() != 0) revert CommitAfterMintStarted();
        if (commitment == bytes32(0)) revert ZeroCommitment();
        revealCommitment = commitment;
        emit RevealCommitted(commitment);
    }

    /// @notice Owner, one way: ends minting for good, whatever stage is open, and sets the
    ///         reveal's target block REVEAL_DELAY_BLOCKS ahead. Sell-out does the same by itself.
    function closeMint() external onlyOwner {
        if (mintClosed) revert MintIsClosed();
        if (revealCommitment == bytes32(0)) revert RevealNotCommitted();
        _closeMint(false, _totalMinted());
    }

    function _closeMint(bool soldOut, uint256 minted) internal {
        mintClosed = true;
        uint256 target = block.number + REVEAL_DELAY_BLOCKS;
        revealTargetBlock = target;
        emit MintClosed(minted, target, soldOut);
    }

    /// @notice The block whose hash a capture right now would store: the target, or the target
    ///         plus whole strides if the target's hash has already aged out. Reverts before the
    ///         target is reached.
    function entropyCandidate() public view returns (uint256) {
        uint256 target = revealTargetBlock;
        if (target == 0) revert MintStillOpen();
        if (block.number <= target) revert TargetBlockNotReached(target, block.number);
        uint256 strides = (block.number - 1 - target) / ENTROPY_STRIDE;
        return target + strides * ENTROPY_STRIDE;
    }

    /// @notice Anyone, once the target block has passed. Stores the candidate block's hash.
    ///         From then on the outcome is fixed; nothing can change it, the owner included.
    function captureEntropy() external {
        if (revealed) revert AlreadyRevealed();
        if (revealEntropy != bytes32(0)) revert EntropyAlreadyCaptured(revealEntropyBlock);
        uint256 candidate = entropyCandidate();
        bytes32 h = blockhash(candidate);
        if (h == bytes32(0)) revert BlockHashUnavailable(candidate);
        revealEntropy = h;
        revealEntropyBlock = candidate;
        emit EntropyCaptured(candidate, h, candidate != revealTargetBlock);
    }

    /// @notice Anyone who knows the secret, any time after the entropy is captured. Proves the
    ///         secret against the commitment and derives the offset. No deadline.
    function reveal(bytes32 secret) external {
        if (revealed) revert AlreadyRevealed();
        bytes32 entropy = revealEntropy;
        if (entropy == bytes32(0)) revert EntropyNotCaptured();
        if (keccak256(abi.encodePacked(secret)) != revealCommitment) revert WrongSecret();
        uint256 offset = uint256(keccak256(abi.encode(secret, entropy))) % maxSupply();
        revealed = true;
        revealOffset = offset;
        emit Revealed(secret, entropy, offset);
        if (totalSupply() != 0) emit BatchMetadataUpdate(_startTokenId(), _nextTokenId() - 1);
    }

    // ---------------------------------------------------------------------------------------
    // Interfaces
    // ---------------------------------------------------------------------------------------

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721A, ERC721SeaDrop, IERC721A)
        returns (bool)
    {
        return ERC721SeaDrop.supportsInterface(interfaceId);
    }

    // The next three exist only because ERC721SeaDrop and ERC721AQueryable share ERC721A as a
    // base, so Solidity asks this contract to say which definition wins. SeaDrop's does.

    function _baseURI() internal view virtual override(ERC721A, ERC721ContractMetadata) returns (string memory) {
        return ERC721ContractMetadata._baseURI();
    }

    function _startTokenId() internal view virtual override(ERC721A, ERC721SeaDrop) returns (uint256) {
        return ERC721SeaDrop._startTokenId();
    }

    function isApprovedForAll(address owner, address spender)
        public
        view
        virtual
        override(ERC721A, ERC721AConduitPreapproved, IERC721A)
        returns (bool)
    {
        return ERC721AConduitPreapproved.isApprovedForAll(owner, spender);
    }
}
