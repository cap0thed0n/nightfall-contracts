// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Ownable } from "openzeppelin-contracts/access/Ownable.sol";
import { Base64 } from "openzeppelin-contracts/utils/Base64.sol";
import { Strings } from "openzeppelin-contracts/utils/Strings.sol";
import { SSTORE2 } from "sstore2/SSTORE2.sol";
import { INightfallRenderer } from "./interfaces/INightfallRenderer.sol";
import { LayerSet } from "./lib/LayerSet.sol";

/**
 * @title  NightfallRenderer
 * @notice Composes a Nightfall character from on-chain 16 x 16 trait layers at read time and
 *         returns its metadata as a data: URI. Read-only after the art is frozen; a display bug
 *         is fixed by deploying a new renderer and pointing the token contract at it.
 *
 *         Art is loaded in categories, drawn first to last in the order they were added
 *         (Background, Body, Clothing, Hair, Eyes/Eyewear, Headwear, Face Accessory, and on
 *         Operators Held). The level-tier border is drawn last, on top of everything, when the
 *         token contract passes a tier above 0. Genesis pass 0 and get no border.
 *
 *         The trait table is one byte per category per row: 0xFF for no layer, otherwise the
 *         layer index inside that category. Its keccak256 is the provenance hash the token
 *         contract commits to before the first mint. A token's row is (tokenId + offset) mod
 *         rowCount, where offset comes from the token contract's commit-reveal.
 *
 *         A category's layers live in one or more chunks, each its own SSTORE2 LayerSet with its
 *         own colour table, so a category can keep growing: cosmetic traits are appended to their
 *         category over time (`addLayers`), and a token wearing one passes it in `traits`, which
 *         replaces that category's layer from the table. Layer indices run across the chunks, up
 *         to MAX_LAYERS_PER_CATEGORY.
 *
 *         Before the reveal every token shows the same pre-reveal image: an animated GIF stored
 *         once, byte for byte as it was drawn, and served as a data: URI. Without one set, the
 *         fixed SVG below stands in. It can be replaced until the bound token's first mint.
 */
/// @notice The one thing the renderer asks of its token: whether anything is minted yet.
interface IMinted {
    function totalSupply() external view returns (uint256);
}

contract NightfallRenderer is INightfallRenderer, Ownable {
    using LayerSet for bytes;

    struct Category {
        string name;
        address[] chunks; // SSTORE2 pointers, each a LayerSet blob
        uint256[] chunkStarts; // the global index of each chunk's first layer
        string[] layerNames; // every layer across the chunks, in index order
    }

    /// @dev Each cosmetic's supply cap, by category and layer, set at upload. Base layers have none.
    mapping(uint256 => mapping(uint256 => uint256)) internal _caps;

    uint8 public constant NO_LAYER = 0xFF;
    /// @notice Layer indices in a token's traits are 16 bits.
    uint256 public constant MAX_LAYERS_PER_CATEGORY = 65_535;
    /// @notice Categories are numbered by one byte in a token's traits.
    uint256 public constant MAX_CATEGORIES = 256;

    string public collectionName;
    string public description;
    Category[] internal _categories;
    address internal _table;
    uint256 public rowCount;
    uint24[] internal _tierColours;
    /// @notice Once frozen, the base art is final: no category added or replaced, no table,
    ///         no tier colour. New cosmetic layers can still be appended to a category
    ///         (`addLayers`), so upgrades keep working for ever.
    bool public frozen;
    address internal _preReveal; // SSTORE2 pointer to the pre-reveal GIF, stored as uploaded
    /// @notice The token this renderer draws. Bound once; its first mint fixes the pre-reveal image.
    address public token;

    event CategoryAdded(uint256 indexed index, string name, uint256 layers, uint256 colours);
    event CategoryReplaced(uint256 indexed index, string name, uint256 layers, uint256 colours);
    event LayersAdded(uint256 indexed index, uint256 firstLayer, uint256 layers, uint256 colours);
    /// @notice A cosmetic's supply cap, fixed at upload: at most `cap` tokens ever wear it.
    event CosmeticCapSet(uint256 indexed category, uint256 indexed layer, uint256 cap);
    event TokenBound(address token);
    event TableSet(uint256 rows, bytes32 tableHash);
    event TierColoursSet(uint256 count);
    event Frozen();
    event PreRevealImageSet(uint256 bytesLength, bytes32 imageHash);

    error IsFrozen();
    error NoCategories();
    error CategoryOutOfRange(uint256 index);
    error LayerNamesMismatch(uint256 names, uint256 layers);
    error TableNotDivisible(uint256 length, uint256 categories);
    error TableLayerOutOfRange(uint256 row, uint256 category, uint256 layer);
    error TableNotSet();
    error TooManyTiers(uint256 count);
    error NotAGif();
    error TooManyCategories();
    error TooManyLayers(uint256 category, uint256 total);
    error TokenAlreadyBound();
    error TokenNotBound();
    error PreRevealFixed();
    error BadTraits();
    error CapsMismatch(uint256 caps, uint256 layers);
    error ZeroCap(uint256 category, uint256 layer);
    error ImageTooLarge(uint256 length, uint256 limit);

    constructor(string memory collectionName_, string memory description_) {
        collectionName = collectionName_;
        description = description_;
    }

    // ---------------------------------------------------------------------------------------
    // Loading the art. Owner only, refused once frozen.
    // ---------------------------------------------------------------------------------------

    function _notFrozen() internal view {
        if (frozen) revert IsFrozen();
    }

    /// @notice Appends a category. Categories draw in the order they are added.
    function addCategory(string calldata name, bytes calldata blob, string[] calldata names)
        external
        onlyOwner
        returns (uint256 index)
    {
        _notFrozen();
        index = _categories.length;
        if (index >= MAX_CATEGORIES) revert TooManyCategories();
        _categories.push();
        _store(index, name, blob, names);
        emit CategoryAdded(index, name, names.length, blob.colourCount());
    }

    /// @notice Appends new layers (cosmetic traits) to an existing category as a new chunk,
    ///         after every layer it already has. Existing layers and indices never move. Owner
    ///         only. Works after the freeze: the freeze fixes the base art, not the cosmetics.
    ///         `caps` sets each new cosmetic's supply cap, one per layer, at least 1: the token
    ///         refuses to apply a cosmetic once that many tokens have had it applied. A cap is
    ///         fixed for good at upload.
    function addLayers(uint256 index, bytes calldata blob, string[] calldata names, uint256[] calldata caps) external onlyOwner returns (uint256 firstLayer) {
        if (index >= _categories.length) revert CategoryOutOfRange(index);
        bytes memory b = blob;
        b.validate();
        uint256 layers = b.layerCount();
        if (names.length != layers) revert LayerNamesMismatch(names.length, layers);
        if (caps.length != layers) revert CapsMismatch(caps.length, layers);
        Category storage c = _categories[index];
        firstLayer = c.layerNames.length;
        if (firstLayer + layers > MAX_LAYERS_PER_CATEGORY) revert TooManyLayers(index, firstLayer + layers);
        c.chunks.push(SSTORE2.write(b));
        c.chunkStarts.push(firstLayer);
        for (uint256 i = 0; i < layers; ++i) {
            if (caps[i] == 0) revert ZeroCap(index, firstLayer + i);
            c.layerNames.push(names[i]);
            _caps[index][firstLayer + i] = caps[i];
            emit CosmeticCapSet(index, firstLayer + i, caps[i]);
        }
        emit LayersAdded(index, firstLayer, layers, b.colourCount());
    }

    /// @inheritdoc INightfallRenderer
    function cosmeticCap(uint256 category, uint256 layer) external view returns (uint256) {
        return _caps[category][layer];
    }

    /// @notice Replaces a category's art in place, keeping its position in the stack.
    function replaceCategory(uint256 index, string calldata name, bytes calldata blob, string[] calldata names)
        external
        onlyOwner
    {
        _notFrozen();
        if (index >= _categories.length) revert CategoryOutOfRange(index);
        _store(index, name, blob, names);
        emit CategoryReplaced(index, name, names.length, blob.colourCount());
    }

    function _store(uint256 index, string calldata name, bytes calldata blob, string[] calldata names) internal {
        bytes memory b = blob;
        b.validate();
        uint256 layers = b.layerCount();
        if (names.length != layers) revert LayerNamesMismatch(names.length, layers);
        if (layers > MAX_LAYERS_PER_CATEGORY) revert TooManyLayers(index, layers);
        Category storage c = _categories[index];
        c.name = name;
        delete c.chunks;
        delete c.chunkStarts;
        c.chunks.push(SSTORE2.write(b));
        c.chunkStarts.push(0);
        delete c.layerNames;
        for (uint256 i = 0; i < layers; ++i) c.layerNames.push(names[i]);
    }

    /// @notice Sets the trait table: rowCount rows of one byte per category. Refuses a table
    ///         that names a layer a category does not have.
    function setTable(bytes calldata rows) external onlyOwner {
        _notFrozen();
        uint256 categories = _categories.length;
        if (categories == 0) revert NoCategories();
        if (rows.length == 0 || rows.length % categories != 0) revert TableNotDivisible(rows.length, categories);
        uint256 count = rows.length / categories;
        uint256[] memory layersPer = new uint256[](categories);
        for (uint256 c = 0; c < categories; ++c) layersPer[c] = _categories[c].layerNames.length;
        for (uint256 r = 0; r < count; ++r) {
            for (uint256 c = 0; c < categories; ++c) {
                uint256 v = uint8(rows[r * categories + c]);
                if (v != NO_LAYER && v >= layersPer[c]) revert TableLayerOutOfRange(r, c, v);
            }
        }
        _table = SSTORE2.write(rows);
        rowCount = count;
        emit TableSet(count, keccak256(rows));
    }

    /// @notice Border colours by tier, index 0 for tier 1. At most 15 tiers.
    function setTierColours(uint24[] calldata colours) external onlyOwner {
        _notFrozen();
        if (colours.length > 15) revert TooManyTiers(colours.length);
        _tierColours = colours;
        emit TierColoursSet(colours.length);
    }

    /// @notice The largest image one SSTORE2 contract can hold: the 24,576-byte code limit
    ///         less SSTORE2's one-byte prefix.
    uint256 public constant MAX_PRE_REVEAL_BYTES = 24_575;

    /// @notice Binds the token this renderer draws, once. Its first mint fixes the pre-reveal image.
    function bindToken(address token_) external onlyOwner {
        if (token != address(0)) revert TokenAlreadyBound();
        token = token_;
        emit TokenBound(token_);
    }

    /// @notice Stores the image every token shows before the reveal: a GIF, exactly as given,
    ///         never resized or recompressed. Owner only, and only until the bound token's first
    ///         mint: buyers see the image they minted under, and it never changes after.
    function setPreRevealImage(bytes calldata gif) external onlyOwner {
        if (token == address(0)) revert TokenNotBound();
        if (IMinted(token).totalSupply() != 0) revert PreRevealFixed();
        if (gif.length > MAX_PRE_REVEAL_BYTES) revert ImageTooLarge(gif.length, MAX_PRE_REVEAL_BYTES);
        if (gif.length < 6 || bytes4(gif[0:4]) != "GIF8" || gif[5] != "a" || (gif[4] != "7" && gif[4] != "9")) revert NotAGif();
        _preReveal = SSTORE2.write(gif);
        emit PreRevealImageSet(gif.length, keccak256(gif));
    }

    /// @notice The stored pre-reveal GIF, byte for byte. Empty while none is set.
    function preRevealImage() public view returns (bytes memory) {
        if (_preReveal == address(0)) return "";
        return SSTORE2.read(_preReveal);
    }

    /// @notice Freezes the art forever. Call once the art is final and the table is committed.
    function freeze() external onlyOwner {
        _notFrozen();
        if (_table == address(0)) revert TableNotSet();
        frozen = true;
        emit Frozen();
    }

    // ---------------------------------------------------------------------------------------
    // Reading the art.
    // ---------------------------------------------------------------------------------------

    function categoryCount() external view returns (uint256) {
        return _categories.length;
    }

    function categoryName(uint256 index) external view returns (string memory) {
        if (index >= _categories.length) revert CategoryOutOfRange(index);
        return _categories[index].name;
    }

    function layerNames(uint256 index) external view returns (string[] memory) {
        if (index >= _categories.length) revert CategoryOutOfRange(index);
        return _categories[index].layerNames;
    }

    /// @notice How many layers a category holds across its chunks, base and cosmetic.
    function layerCount(uint256 index) public view returns (uint256) {
        if (index >= _categories.length) revert CategoryOutOfRange(index);
        return _categories[index].layerNames.length;
    }

    function chunkCount(uint256 index) external view returns (uint256) {
        if (index >= _categories.length) revert CategoryOutOfRange(index);
        return _categories[index].chunks.length;
    }

    /// @notice The raw LayerSet blob of a category's first chunk (the base art), so anyone can
    ///         rebuild the art off-chain. `layerSetChunk` reads the later ones.
    function layerSet(uint256 index) external view returns (bytes memory) {
        return layerSetChunk(index, 0);
    }

    function layerSetChunk(uint256 index, uint256 chunk) public view returns (bytes memory) {
        if (index >= _categories.length) revert CategoryOutOfRange(index);
        return SSTORE2.read(_categories[index].chunks[chunk]);
    }

    /// @notice The whole trait table. keccak256 of this is the provenance hash.
    function table() public view returns (bytes memory) {
        if (_table == address(0)) revert TableNotSet();
        return SSTORE2.read(_table);
    }

    function tableHash() external view returns (bytes32) {
        return keccak256(table());
    }

    function tierColours() external view returns (uint24[] memory) {
        return _tierColours;
    }

    /// @notice The row a token renders once revealed.
    function rowOf(uint256 tokenId, uint256 offset) public view returns (uint256) {
        uint256 rows = rowCount;
        if (rows == 0) revert TableNotSet();
        // Reduced first so no offset, however large, can overflow the sum.
        return ((tokenId % rows) + (offset % rows)) % rows;
    }

    /// @notice One row of the table, one byte per category.
    function row(uint256 index) public view returns (bytes memory out) {
        bytes memory t = table();
        uint256 categories = _categories.length;
        if (index >= rowCount) revert TableLayerOutOfRange(index, 0, 0);
        out = new bytes(categories);
        for (uint256 c = 0; c < categories; ++c) out[c] = t[index * categories + c];
    }

    // ---------------------------------------------------------------------------------------
    // Rendering.
    // ---------------------------------------------------------------------------------------

    function tokenURI(uint256 tokenId, bool revealed, uint256 offset, uint8 tier, bytes calldata traits)
        external
        view
        override
        returns (string memory)
    {
        string memory id = Strings.toString(tokenId);
        bytes memory image;
        string memory attributes;
        if (revealed) {
            uint256[] memory layers = layersOf(rowOf(tokenId, offset), traits);
            (uint24[256] memory px, bool[256] memory on) = _composite(layers, tier);
            image = abi.encodePacked("data:image/svg+xml;base64,", Base64.encode(bytes(_emit(px, on))));
            attributes = _attributes(layers);
        } else {
            image = unrevealedImage();
            attributes = "[]";
        }
        bytes memory json = abi.encodePacked(
            '{"name":"',
            collectionName,
            " #",
            id,
            '","description":"',
            description,
            '","image":"',
            image,
            '","attributes":',
            attributes,
            "}"
        );
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(json)));
    }

    /// @notice The SVG for a table row with an optional tier border. viewBox 0 0 16 16 with
    ///         crisp edges, so it scales to any size with hard pixels.
    function svg(uint256 rowIndex, uint8 tier) public view returns (string memory) {
        (uint24[256] memory px, bool[256] memory on) = _composite(layersOf(rowIndex, ""), tier);
        return _emit(px, on);
    }

    /// @notice The layer each category draws for a table row, with a token's traits applied:
    ///         `traits` is three bytes per entry (category, then a 16-bit layer index), each
    ///         replacing that category's layer from the row. NO for a category with no layer.
    function layersOf(uint256 rowIndex, bytes memory traits) public view returns (uint256[] memory layers) {
        bytes memory r = row(rowIndex);
        uint256 categories = _categories.length;
        layers = new uint256[](categories);
        for (uint256 c = 0; c < categories; ++c) layers[c] = uint8(r[c]) == NO_LAYER ? NO : uint8(r[c]);
        if (traits.length % 3 != 0) revert BadTraits();
        for (uint256 i = 0; i < traits.length; i += 3) {
            uint256 c = uint8(traits[i]);
            uint256 layer = (uint256(uint8(traits[i + 1])) << 8) | uint8(traits[i + 2]);
            if (c >= categories || layer >= _categories[c].layerNames.length) revert BadTraits();
            layers[c] = layer;
        }
    }

    /// @notice The SVG for a row with a token's traits applied.
    function svgWithTraits(uint256 rowIndex, uint8 tier, bytes calldata traits) external view returns (string memory) {
        (uint24[256] memory px, bool[256] memory on) = _composite(layersOf(rowIndex, traits), tier);
        return _emit(px, on);
    }

    /// @notice The pixels for a row with a token's traits applied, as `pixels` returns them.
    function pixelsWithTraits(uint256 rowIndex, uint8 tier, bytes calldata traits) external view returns (bytes memory out) {
        (uint24[256] memory px, bool[256] memory on) = _composite(layersOf(rowIndex, traits), tier);
        out = _rgba(px, on);
    }

    /// @notice The metadata attributes for a set of layers from `layersOf`.
    function attributesOf(uint256[] memory layers) external view returns (string memory) {
        return _attributes(layers);
    }

    /// @dev Marks a category with no layer in `layersOf`.
    uint256 internal constant NO = type(uint256).max;

    /// @notice The composited image as raw pixels: 256 RGBA quads, row-major, alpha 0 or 255.
    ///         What the SVG draws, in a form a checker can compare byte for byte.
    function pixels(uint256 rowIndex, uint8 tier) external view returns (bytes memory out) {
        (uint24[256] memory px, bool[256] memory on) = _composite(layersOf(rowIndex, ""), tier);
        out = _rgba(px, on);
    }

    function _rgba(uint24[256] memory px, bool[256] memory on) internal pure returns (bytes memory out) {
        out = new bytes(1024);
        for (uint256 p = 0; p < 256; ++p) {
            if (!on[p]) continue;
            out[p * 4] = bytes1(uint8(px[p] >> 16));
            out[p * 4 + 1] = bytes1(uint8(px[p] >> 8));
            out[p * 4 + 2] = bytes1(uint8(px[p]));
            out[p * 4 + 3] = bytes1(uint8(255));
        }
    }

    /// @dev Layers in order, a painted pixel covering what is under it, then the border ring
    ///      last when the tier has a colour.
    function _composite(uint256[] memory layers, uint8 tier) internal view returns (uint24[256] memory px, bool[256] memory on) {
        uint256 categories = layers.length;
        for (uint256 c = 0; c < categories; ++c) {
            if (layers[c] == NO) continue;
            (bytes memory palette, bytes memory lp) = _layer(_categories[c], layers[c]);
            for (uint256 p = 0; p < 256; ++p) {
                uint256 v = uint8(lp[p]);
                if (v != 0) {
                    uint256 at = 3 * (v - 1);
                    px[p] = (uint24(uint8(palette[at])) << 16) | (uint24(uint8(palette[at + 1])) << 8) | uint24(uint8(palette[at + 2]));
                    on[p] = true;
                }
            }
        }
        if (tier != 0 && tier <= _tierColours.length) {
            uint24 border = _tierColours[tier - 1];
            for (uint256 i = 0; i < 16; ++i) {
                px[i] = border;
                on[i] = true; // top row
                px[240 + i] = border;
                on[240 + i] = true; // bottom row
                px[i * 16] = border;
                on[i * 16] = true; // left column
                px[i * 16 + 15] = border;
                on[i * 16 + 15] = true; // right column
            }
        }
    }

    /// @dev One layer's colour table and its 256 pixels, read as slices of the chunk that holds
    ///      it, so the cost does not grow with how many layers a category has.
    function _layer(Category storage cat, uint256 layer) internal view returns (bytes memory palette, bytes memory lp) {
        uint256 i = cat.chunkStarts.length - 1;
        while (cat.chunkStarts[i] > layer) --i;
        address chunk = cat.chunks[i];
        uint256 colours = uint8(SSTORE2.read(chunk, 0, 1)[0]);
        uint256 start = 1 + 3 * colours;
        palette = SSTORE2.read(chunk, 1, start);
        uint256 at = start + (layer - cat.chunkStarts[i]) * 256;
        lp = SSTORE2.read(chunk, at, at + 256);
    }

    /// @notice The image URI every token shows before the reveal: the stored GIF as a data: URI,
    ///         or the fixed SVG while no GIF is set. Not the art.
    function unrevealedImage() public view returns (bytes memory) {
        if (_preReveal != address(0)) return abi.encodePacked("data:image/gif;base64,", Base64.encode(SSTORE2.read(_preReveal)));
        return abi.encodePacked("data:image/svg+xml;base64,", Base64.encode(bytes(unrevealedSvg())));
    }

    /// @notice The fixed image every token shows before the reveal while no GIF is set.
    function unrevealedSvg() public pure returns (string memory) {
        return
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" shape-rendering="crispEdges">'
            '<rect width="16" height="16" fill="#0b0b16"/>'
            '<rect x="6" y="3" width="4" height="1" fill="#ff2d95"/>'
            '<rect x="5" y="4" width="1" height="2" fill="#ff2d95"/>'
            '<rect x="10" y="4" width="1" height="3" fill="#ff2d95"/>'
            '<rect x="8" y="7" width="2" height="1" fill="#ff2d95"/>'
            '<rect x="7" y="8" width="2" height="2" fill="#ff2d95"/>'
            '<rect x="7" y="12" width="2" height="2" fill="#2de2ff"/>'
            "</svg>";
    }

    /// @dev One rect per horizontal run of one colour, the cheapest correct SVG for 16 x 16.
    function _emit(uint24[256] memory px, bool[256] memory on) internal pure returns (string memory) {
        bytes memory out = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" shape-rendering="crispEdges">';
        for (uint256 y = 0; y < 16; ++y) {
            uint256 x = 0;
            while (x < 16) {
                uint256 i = y * 16 + x;
                if (!on[i]) {
                    ++x;
                    continue;
                }
                uint24 c = px[i];
                uint256 w = 1;
                while (x + w < 16 && on[i + w] && px[i + w] == c) ++w;
                out = abi.encodePacked(
                    out,
                    '<rect x="',
                    Strings.toString(x),
                    '" y="',
                    Strings.toString(y),
                    '" width="',
                    Strings.toString(w),
                    '" height="1" fill="#',
                    _hex(c),
                    '"/>'
                );
                x += w;
            }
        }
        return string(abi.encodePacked(out, "</svg>"));
    }

    function _attributes(uint256[] memory layers) internal view returns (string memory) {
        bytes memory out = "[";
        bool first = true;
        uint256 categories = layers.length;
        for (uint256 c = 0; c < categories; ++c) {
            uint256 layer = layers[c];
            if (layer == NO) continue;
            out = abi.encodePacked(
                out,
                first ? "" : ",",
                '{"trait_type":"',
                _categories[c].name,
                '","value":"',
                _categories[c].layerNames[layer],
                '"}'
            );
            first = false;
        }
        return string(abi.encodePacked(out, "]"));
    }

    function _hex(uint24 c) internal pure returns (string memory) {
        bytes16 digits = "0123456789abcdef";
        bytes memory s = new bytes(6);
        for (uint256 i = 0; i < 6; ++i) {
            s[5 - i] = digits[c & 0xf];
            c >>= 4;
        }
        return string(s);
    }
}
