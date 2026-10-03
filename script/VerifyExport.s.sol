// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { NightfallRenderer } from "../src/NightfallRenderer.sol";
import { ArtFile } from "./ArtFile.sol";

/**
 * @notice Feeds a Trait Forge on-chain export through the real renderer, in a local simulation,
 *         and compares every sample token with the picture Trait Forge drew. Also refuses an
 *         export whose table never uses one of its traits. Nothing is sent to a chain.
 *
 *           forge script script/VerifyExport.s.sol --sig "run(string)" deploy/art/genesis.json
 *
 *         `runFull` is the same check against a picture of every row, which tools/art-check.mjs
 *         writes to <export>.pixels.bin from the token PNGs. That is the 555 of 555 proof
 *         through the Solidity renderer before any deploy:
 *
 *           forge script script/VerifyExport.s.sol --sig "runFull(string,string)" \
 *             deploy/art/private/genesis.json deploy/art/private/genesis.pixels.bin
 */
contract VerifyExport is Script {
    function run(string memory path) external returns (bool ok) {
        return _check(ArtFile.load(path), false);
    }

    function runFull(string memory path, string memory pixelsPath) external returns (bool ok) {
        return _check(ArtFile.loadFull(path, pixelsPath), true);
    }

    function _check(ArtFile.Art memory art, bool full) internal returns (bool ok) {
        NightfallRenderer renderer = new NightfallRenderer(art.collection, "verify");
        ArtFile.loadInto(art, renderer);
        uint256[] memory bad = ArtFile.verify(art, renderer);
        string[] memory missing = ArtFile.missingTraits(art);
        uint256 layers;
        for (uint256 i = 0; i < art.categories.length; ++i) layers += art.categories[i].layers.length;
        console2.log("collection      ", art.collection);
        console2.log("categories      ", art.categories.length);
        console2.log("layers          ", layers);
        console2.log("rows            ", art.rows);
        console2.log("rows checked    ", ArtFile.checkedRows(art), "of", art.rows);
        console2.log("provenance hash ", vm.toString(art.provenanceHash));
        console2.log("renderer hash   ", vm.toString(renderer.tableHash()));
        ok = true;
        if (missing.length != 0) {
            ok = false;
            console2.log("MISSING TRAITS  ", missing.length);
            for (uint256 i = 0; i < missing.length; ++i) console2.log("  never used:   ", missing[i]);
        } else {
            console2.log("traits           every exported trait appears in the table");
        }
        if (bad.length != 0) {
            ok = false;
            for (uint256 i = 0; i < bad.length; ++i) console2.log("MISMATCH on row ", bad[i]);
        } else {
            console2.log("pixels           every checked row renders as the picture in the file");
        }
        if (full && !ArtFile.isFull(art)) {
            ok = false;
            console2.log("NOT FULL         a picture of every row is needed; run tools/art-check.mjs first");
        }
        console2.log(ok ? "RESULT           PASS" : "RESULT           FAIL");
    }
}
