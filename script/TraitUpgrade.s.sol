// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Script, console2 } from "forge-std/Script.sol";
import { NightfallGenesis } from "../src/NightfallGenesis.sol";
import { NightfallRenderer } from "../src/NightfallRenderer.sol";
import { CosmeticVoucherAuthority } from "../src/authority/CosmeticVoucherAuthority.sol";
import { PlaceholderArt } from "../src/art/PlaceholderArt.sol";

/**
 * @notice The rehearsal's trait upgrade, on testnet or the throwaway only.
 *
 *         `enable` deploys the voucher authority with the throwaway cosmetics key
 *         (COSMETICS_SIGNER_KEY in contracts/.env, its own key, never the deployer's or the
 *         operator's) and switches upgrades on. `upload` appends the test crown to a category.
 *         `voucher` signs a voucher with that key, the way the game server will, and prints the
 *         proof the player passes to `applyTrait`. Nothing is sent by `voucher`.
 *
 *   forge script script/TraitUpgrade.s.sol --sig "enable(address)" <token> --rpc-url robinhood_testnet --broadcast
 *   forge script script/TraitUpgrade.s.sol --sig "upload(address,uint256,uint256)" <renderer> 5 100 --rpc-url robinhood_testnet --broadcast
 *   forge script script/TraitUpgrade.s.sol --sig "uploadFile(address,string)" <renderer> deploy/cosmetics/neon-visor.json --rpc-url robinhood_testnet --broadcast
 *   forge script script/TraitUpgrade.s.sol --sig "voucher(address,address,uint256,uint256,uint256,uint256)" <authority> <player> <tokenId> 5 <layer> <voucherId> --rpc-url robinhood_testnet
 */
contract TraitUpgrade is Script {
    /// @dev Testnet and a local chain; Robinhood mainnet only for the throwaway, with THROWAWAY=true.
    function _testnetOrThrowaway() internal view {
        bool throwaway = block.chainid == 4663 && vm.envOr("THROWAWAY", false);
        require(block.chainid == 46630 || block.chainid == 31337 || throwaway, "testnet or the throwaway only");
    }

    function enable(address token) external returns (CosmeticVoucherAuthority authority) {
        _testnetOrThrowaway();
        address signer = vm.addr(vm.envUint("COSMETICS_SIGNER_KEY"));
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        authority = new CosmeticVoucherAuthority(token, signer);
        NightfallGenesis(token).setTraitAuthority(address(authority));
        vm.stopBroadcast();
        console2.log("CosmeticVoucherAuthority", address(authority));
        console2.log("cosmetics signer        ", signer);
    }

    /// @notice Uploads the test crown with a supply cap of `cap` (the most tokens that may ever wear it).
    function upload(address renderer, uint256 category, uint256 cap) external returns (uint256 layer) {
        _testnetOrThrowaway();
        string[] memory names = new string[](1);
        names[0] = "Test Crown";
        uint256[] memory caps = new uint256[](1);
        caps[0] = cap;
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        layer = NightfallRenderer(renderer).addLayers(category, PlaceholderArt.cosmeticCrown(), names, caps);
        vm.stopBroadcast();
        console2.log("category", category);
        console2.log("new layer index", layer);
    }

    /// @notice Uploads a cosmetic of your own: the file `node tools/cosmetic-blob.mjs` wrote from a
    ///         16 x 16 PNG, with its name, its category (an index, or a name the renderer knows)
    ///         and its supply cap. The layer set is checked again here the way the renderer will.
    function uploadFile(address renderer, string memory file) external returns (uint256 layer) {
        _testnetOrThrowaway();
        string memory json = vm.readFile(file);
        require(keccak256(bytes(vm.parseJsonString(json, ".format"))) == keccak256("nightfall-cosmetic"), "not a nightfall-cosmetic file");
        require(vm.parseJsonUint(json, ".version") == 1, "unsupported cosmetic file version");
        NightfallRenderer r = NightfallRenderer(renderer);
        uint256 category = _category(r, json);
        string[] memory names = new string[](1);
        names[0] = vm.parseJsonString(json, ".name");
        uint256[] memory caps = new uint256[](1);
        caps[0] = vm.parseJsonUint(json, ".cap");
        require(caps[0] > 0, "cap must be 1 or more");
        bytes memory blob = vm.parseJsonBytes(json, ".blob");
        require(blob.length == 1 + 3 * uint8(blob[0]) + 256, "blob is not one 16 x 16 layer with its palette");
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        layer = r.addLayers(category, blob, names, caps);
        vm.stopBroadcast();
        console2.log("cosmetic       ", names[0]);
        console2.log("category       ", category, r.categoryName(category));
        console2.log("new layer index", layer);
        console2.log("supply cap     ", caps[0]);
    }

    /// @dev The category as an index, or by its name on the renderer.
    function _category(NightfallRenderer r, string memory json) internal view returns (uint256) {
        bytes memory raw = vm.parseJson(json, ".category");
        // A number parses as a uint256 word; a string is longer and starts with its offset.
        if (raw.length == 32) {
            uint256 index = abi.decode(raw, (uint256));
            require(index < r.categoryCount(), "category index out of range");
            return index;
        }
        string memory name = vm.parseJsonString(json, ".category");
        uint256 count = r.categoryCount();
        for (uint256 i = 0; i < count; ++i) {
            if (keccak256(bytes(r.categoryName(i))) == keccak256(bytes(name))) return i;
        }
        revert(string(abi.encodePacked("no category named ", name)));
    }

    /// @notice Signs a voucher valid for one hour and prints the proof for `applyTrait`.
    function voucher(address authority, address player, uint256 tokenId, uint256 category, uint256 layer, uint256 voucherId) external view returns (bytes memory proof) {
        _testnetOrThrowaway();
        CosmeticVoucherAuthority a = CosmeticVoucherAuthority(authority);
        CosmeticVoucherAuthority.Voucher memory v = CosmeticVoucherAuthority.Voucher(player, tokenId, category, layer, voucherId, block.timestamp + 1 hours);
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(vm.envUint("COSMETICS_SIGNER_KEY"), a.voucherDigest(v));
        proof = abi.encode(v, abi.encodePacked(r, s, sv));
        console2.log("expires at", v.expiresAt);
        console2.log("proof (pass as the last argument of applyTrait):");
        console2.logBytes(proof);
    }
}
