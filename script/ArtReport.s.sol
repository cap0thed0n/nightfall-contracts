// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { NightfallRenderer } from "../src/NightfallRenderer.sol";
import { ArtFile } from "./ArtFile.sol";

/**
 * @notice The per-row gas and size report for an export: what a `tokenURI` call costs and
 *         returns for every row, in a local simulation, so the worst token is known before any
 *         deploy. Writes reports/<name>-rows.csv (row, gas, svg bytes, uri bytes) and prints the
 *         summary. Numbers only; no pixel leaves the machine.
 *
 *           forge script script/ArtReport.s.sol --sig "run(string,string)" deploy/art/private/genesis.json genesis
 *
 *         Thresholds: public RPCs cap eth_call around 50M gas and marketplaces fetch data URIs
 *         of a few hundred KB without trouble, so the report flags anything over 25M gas or
 *         128 KB, half of each, to leave room for the token contract's own overhead.
 */
contract ArtReport is Script {
    uint256 public constant GAS_LIMIT = 25_000_000;
    uint256 public constant URI_LIMIT = 128 * 1024;

    struct Row {
        uint256 gas;
        uint256 svgBytes;
        uint256 uriBytes;
    }

    function run(string memory path, string memory name) external returns (uint256 worstGas, uint256 worstUri) {
        ArtFile.Art memory art = ArtFile.load(path);
        NightfallRenderer renderer = new NightfallRenderer(art.collection, "report");
        ArtFile.loadInto(art, renderer);
        uint24[] memory tiers = new uint24[](3);
        tiers[0] = 0xffffffff >> 8;
        tiers[1] = 0x2fbf71;
        tiers[2] = 0x9b5de5;
        renderer.setTierColours(tiers);

        // reports/ is regenerated, never committed: a fresh clone has none until this makes it.
        vm.createDir("reports", true);
        string memory file = string(abi.encodePacked("reports/", name, "-rows.csv"));
        vm.writeFile(file, "row,gas,svg_bytes,uri_bytes\n");
        uint256 worstRow;
        uint256 worstUriRow;
        uint256 gasSum;
        uint256 uriSum;
        uint256 overGas;
        uint256 overUri;
        for (uint256 r = 0; r < art.rows; ++r) {
            Row memory row = _measure(renderer, r, 0);
            gasSum += row.gas;
            uriSum += row.uriBytes;
            if (row.gas > worstGas) {
                worstGas = row.gas;
                worstRow = r;
            }
            if (row.uriBytes > worstUri) {
                worstUri = row.uriBytes;
                worstUriRow = r;
            }
            if (row.gas > GAS_LIMIT) ++overGas;
            if (row.uriBytes > URI_LIMIT) ++overUri;
            vm.writeLine(
                file,
                string(
                    abi.encodePacked(vm.toString(r), ",", vm.toString(row.gas), ",", vm.toString(row.svgBytes), ",", vm.toString(row.uriBytes))
                )
            );
        }
        // The border adds up to 60 pixels of one colour; measure it on the worst row for each tier.
        uint256 worstTierGas;
        for (uint8 t = 1; t <= 3; ++t) {
            Row memory row = _measure(renderer, worstRow, t);
            if (row.gas > worstTierGas) worstTierGas = row.gas;
        }

        console2.log("rows             ", art.rows);
        console2.log("worst gas        ", worstGas, "on row", worstRow);
        console2.log("worst gas w/ tier", worstTierGas);
        console2.log("mean gas         ", gasSum / art.rows);
        console2.log("worst uri bytes  ", worstUri, "on row", worstUriRow);
        console2.log("mean uri bytes   ", uriSum / art.rows);
        console2.log("rows over gas cap", overGas, "of limit", GAS_LIMIT);
        console2.log("rows over uri cap", overUri, "of limit", URI_LIMIT);
        console2.log("csv written      ", file);
        console2.log(overGas == 0 && overUri == 0 && worstTierGas <= GAS_LIMIT ? "RESULT           PASS" : "RESULT           FAIL");
    }

    /// @dev Calls the view and reads only the returned string's length, never copying the string
    ///      into memory: 555 returned URIs would otherwise exhaust the EVM's quadratic memory.
    function _measure(NightfallRenderer renderer, uint256 row, uint8 tier) internal view returns (Row memory out) {
        // tokenId == row with offset 0 lands on that row (rowOf is (tokenId + offset) mod rows).
        out.gas = _callLength(address(renderer), abi.encodeWithSelector(renderer.tokenURI.selector, row, true, 0, tier, bytes("")), true);
        out.uriBytes = _callLength(address(renderer), abi.encodeWithSelector(renderer.tokenURI.selector, row, true, 0, tier, bytes("")), false);
        out.svgBytes = _callLength(address(renderer), abi.encodeWithSelector(renderer.svg.selector, row, tier), false);
    }

    function _callLength(address target, bytes memory data, bool wantGas) internal view returns (uint256 result) {
        bool ok;
        uint256 before = gasleft();
        assembly ("memory-safe") {
            ok := staticcall(gas(), target, add(data, 32), mload(data), 0, 0)
        }
        uint256 used = before - gasleft();
        require(ok, "render call failed");
        if (wantGas) return used;
        // The ABI encoding of one string: offset word, length word, then the bytes.
        assembly ("memory-safe") {
            let scratch := mload(0x40)
            returndatacopy(scratch, 32, 32)
            result := mload(scratch)
        }
    }
}
