// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Script, console2 } from "forge-std/Script.sol";
import { SeaDrop } from "seadrop/SeaDrop.sol";
import { PublicDrop } from "seadrop/lib/SeaDropStructs.sol";
import { NightfallGenesis } from "../src/NightfallGenesis.sol";
import { NightfallRenderer } from "../src/NightfallRenderer.sol";
import { PlaceholderArt } from "../src/art/PlaceholderArt.sol";
import { StockToken } from "./local/StockToken.sol";

/**
 * @notice The game's simulated chain: everything the game talks to, deployed on a local anvil
 *         (chain 31337) with anvil's well-known keys, so the game's chain code is tested against
 *         the real contract. A local SeaDrop, the Genesis with its renderer and placeholder art,
 *         the operator set, a public stage at price 0, Genesis minted to two players and a
 *         reserve to the operator wallet, and five stock tokens with the payer holding 30 each.
 *         Writes the addresses to reports/local-game.json. Refuses any chain but 31337.
 *
 *   anvil &
 *   forge script script/LocalGame.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
 */
contract LocalGame is Script {
    // anvil's well-known public default development keys, accounts 0 to 4: the keys every anvil
    // instance prints at startup and Foundry's documentation lists. They are public knowledge, used
    // here only on a local anvil chain (the script refuses any other, below), hold no real funds and
    // are never used on any real network.
    uint256 internal constant DEPLOYER = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant OPERATOR = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant PAYER = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 internal constant PLAYER_A = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 internal constant PLAYER_B = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;

    function run() external {
        require(block.chainid == 31337, "local anvil only");
        address operator = vm.addr(OPERATOR);
        address payer = vm.addr(PAYER);

        vm.startBroadcast(DEPLOYER);
        SeaDrop seadrop = new SeaDrop();
        address[] memory allowed = new address[](1);
        allowed[0] = address(seadrop);
        NightfallGenesis token = new NightfallGenesis("Nightfall Genesis", "NFG", allowed);
        token.setMaxSupply(555);
        token.setOperator(operator);
        token.setMaxLockSeconds(26 hours);
        token.updateCreatorPayoutAddress(address(seadrop), vm.addr(DEPLOYER));
        token.updateAllowedFeeRecipient(address(seadrop), vm.addr(DEPLOYER), true);
        token.updatePublicDrop(
            address(seadrop),
            PublicDrop({ mintPrice: 0, startTime: uint48(block.timestamp), endTime: uint48(block.timestamp + 30 days), maxTotalMintableByWallet: 10, feeBps: 0, restrictFeeRecipients: true })
        );
        NightfallRenderer renderer = new NightfallRenderer("Nightfall Genesis", "A boss of the network.");
        string[] memory names = PlaceholderArt.categoryNames();
        for (uint256 i = 0; i < names.length; ++i) renderer.addCategory(names[i], PlaceholderArt.category(i), PlaceholderArt.layerNames(i));
        renderer.setTable(PlaceholderArt.table(555, keccak256("local game table")));
        token.setRenderer(address(renderer));
        token.setProvenanceHash(renderer.tableHash());
        renderer.bindToken(address(token));
        token.commitReveal(keccak256(abi.encodePacked(keccak256("local game secret"))));

        string[5] memory symbols = ["TSLA", "AMZN", "PLTR", "NFLX", "AMD"];
        address[5] memory stocks;
        for (uint256 i = 0; i < 5; ++i) {
            StockToken s = new StockToken(symbols[i]);
            s.mint(payer, 30 ether);
            stocks[i] = address(s);
        }
        vm.stopBroadcast();

        // Player A holds Genesis 1 to 3, player B 4 and 5, the operator's reserve 6 to 15.
        _mint(seadrop, token, PLAYER_A, 3);
        _mint(seadrop, token, PLAYER_B, 2);
        _mint(seadrop, token, OPERATOR, 10);

        string memory j = "local";
        vm.serializeAddress(j, "seadrop", address(seadrop));
        vm.serializeAddress(j, "genesis", address(token));
        vm.serializeAddress(j, "renderer", address(renderer));
        vm.serializeAddress(j, "operator", operator);
        vm.serializeAddress(j, "payer", payer);
        vm.serializeAddress(j, "playerA", vm.addr(PLAYER_A));
        vm.serializeAddress(j, "playerB", vm.addr(PLAYER_B));
        vm.serializeAddress(j, "TSLA", stocks[0]);
        vm.serializeAddress(j, "AMZN", stocks[1]);
        vm.serializeAddress(j, "PLTR", stocks[2]);
        vm.serializeAddress(j, "NFLX", stocks[3]);
        string memory out = vm.serializeAddress(j, "AMD", stocks[4]);
        vm.writeJson(out, "./reports/local-game.json");
        console2.log("Genesis", address(token));
    }

    function _mint(SeaDrop seadrop, NightfallGenesis token, uint256 key, uint256 quantity) internal {
        vm.startBroadcast(key);
        seadrop.mintPublic(address(token), vm.addr(DEPLOYER), address(0), quantity);
        vm.stopBroadcast();
    }
}
