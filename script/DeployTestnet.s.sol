// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { PublicDrop } from "seadrop/lib/SeaDropStructs.sol";
import { ISeaDropTokenContractMetadata } from "seadrop/interfaces/ISeaDropTokenContractMetadata.sol";
import { NightfallGenesis } from "../src/NightfallGenesis.sol";
import { NightfallRenderer } from "../src/NightfallRenderer.sol";
import { PlaceholderArt } from "../src/art/PlaceholderArt.sol";
import { ArtFile } from "./ArtFile.sol";

/**
 * @notice Deploys the renderer loaded with the placeholder set, then the Genesis token, and
 *         configures both from `deploy/<network>.json`. Run it from the deploying machine:
 *
 *           forge script script/DeployTestnet.s.sol --rpc-url robinhood_testnet --broadcast
 *
 *         Every number comes from the config file. Nothing here is a game-balance number: it
 *         is supply, royalty, lock ceiling and stage timing, all of which are contract terms.
 */
contract DeployTestnet is Script {
    struct Config {
        string name;
        string symbol;
        string description;
        uint256 maxSupply;
        uint96 royaltyBps;
        uint64 maxLockSeconds;
        address seaDrop;
        address transferValidator;
        address royaltyReceiver;
        address operator;
        address creatorPayout;
        address feeRecipient;
        bool restrictFeeRecipients;
        uint80 publicMintPrice;
        uint48 publicStart;
        uint48 publicEnd;
        uint16 publicMaxPerWallet;
        uint16 publicFeeBps;
        bytes32 revealCommitment;
        bytes32 tableSeed;
        uint24[] tierColours;
        string dropURI;
        string contractURI;
        /// Trait Forge's on-chain export. Empty keeps the generated placeholder set.
        string artFile;
        /// The pre-reveal GIF, stored on chain as it is. Empty keeps the fixed SVG.
        string preRevealImage;
    }

    string public constant CONFIG_PATH = "deploy/testnet.json";

    function run() external {
        Config memory c = load(CONFIG_PATH);
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(key);
        (NightfallGenesis token, NightfallRenderer renderer) = deployAll(c);
        vm.stopBroadcast();
        console2.log("NightfallRenderer", address(renderer));
        console2.log("NightfallGenesis ", address(token));
        console2.log("provenance hash  ", vm.toString(renderer.tableHash()));
    }

    /// @notice Reads the config file. Every key is required.
    function load(string memory path) public view returns (Config memory c) {
        string memory json = vm.readFile(path);
        c.name = vm.parseJsonString(json, ".name");
        c.symbol = vm.parseJsonString(json, ".symbol");
        c.description = vm.parseJsonString(json, ".description");
        c.maxSupply = vm.parseJsonUint(json, ".maxSupply");
        c.royaltyBps = uint96(vm.parseJsonUint(json, ".royaltyBps"));
        c.maxLockSeconds = uint64(vm.parseJsonUint(json, ".maxLockSeconds"));
        c.seaDrop = vm.parseJsonAddress(json, ".seaDrop");
        c.transferValidator = vm.parseJsonAddress(json, ".transferValidator");
        c.royaltyReceiver = vm.parseJsonAddress(json, ".royaltyReceiver");
        c.operator = vm.parseJsonAddress(json, ".operator");
        c.creatorPayout = vm.parseJsonAddress(json, ".creatorPayout");
        c.feeRecipient = vm.parseJsonAddress(json, ".feeRecipient");
        c.restrictFeeRecipients = vm.parseJsonBool(json, ".restrictFeeRecipients");
        c.publicMintPrice = uint80(vm.parseJsonUint(json, ".publicMintPrice"));
        c.publicStart = uint48(vm.parseJsonUint(json, ".publicStart"));
        c.publicEnd = uint48(vm.parseJsonUint(json, ".publicEnd"));
        c.publicMaxPerWallet = uint16(vm.parseJsonUint(json, ".publicMaxPerWallet"));
        c.publicFeeBps = uint16(vm.parseJsonUint(json, ".publicFeeBps"));
        c.revealCommitment = vm.parseJsonBytes32(json, ".revealCommitment");
        c.tableSeed = vm.parseJsonBytes32(json, ".tableSeed");
        uint256[] memory tiers = vm.parseJsonUintArray(json, ".tierColours");
        c.tierColours = new uint24[](tiers.length);
        for (uint256 i = 0; i < tiers.length; ++i) c.tierColours[i] = uint24(tiers[i]);
        c.dropURI = vm.parseJsonString(json, ".dropURI");
        c.contractURI = vm.parseJsonString(json, ".contractURI");
        c.artFile = vm.parseJsonString(json, ".artFile");
        c.preRevealImage = vm.parseJsonString(json, ".preRevealImage");
    }

    /// @notice The whole deployment, as one function so a test can run it against a local
    ///         SeaDrop. The caller is the owner of both contracts afterwards.
    function deployAll(Config memory c) public returns (NightfallGenesis token, NightfallRenderer renderer) {
        require(c.seaDrop != address(0), "seaDrop address required");
        require(c.royaltyReceiver != address(0), "royaltyReceiver required");
        require(c.creatorPayout != address(0), "creatorPayout required");
        require(c.feeRecipient != address(0), "feeRecipient required");

        // 1. The renderer: Trait Forge's export when the config names one, else the placeholder
        //    set with a deterministic table. The export is checked against the renderer first.
        renderer = new NightfallRenderer(c.name, c.description);
        if (bytes(c.artFile).length != 0) {
            ArtFile.Art memory art = ArtFile.load(c.artFile);
            require(art.rows == c.maxSupply, "art file rows must equal maxSupply");
            require(ArtFile.missingTraits(art).length == 0, "art file has traits the table never uses");
            ArtFile.loadInto(art, renderer);
            require(ArtFile.verify(art, renderer).length == 0, "art file does not render as Trait Forge drew it");
        } else {
            string[] memory names = PlaceholderArt.categoryNames();
            for (uint256 i = 0; i < names.length; ++i) {
                renderer.addCategory(names[i], PlaceholderArt.category(i), PlaceholderArt.layerNames(i));
            }
            renderer.setTable(PlaceholderArt.table(c.maxSupply, c.tableSeed));
        }
        if (c.tierColours.length > 0) renderer.setTierColours(c.tierColours);

        // 2. The token.
        address[] memory allowed = new address[](1);
        allowed[0] = c.seaDrop;
        token = new NightfallGenesis(c.name, c.symbol, allowed);
        token.setMaxSupply(c.maxSupply);
        token.setRoyaltyInfo(ISeaDropTokenContractMetadata.RoyaltyInfo(c.royaltyReceiver, c.royaltyBps));
        token.setRenderer(address(renderer));
        // The renderer is bound to this token, whose first mint fixes the pre-reveal image.
        renderer.bindToken(address(token));
        if (bytes(c.preRevealImage).length != 0) renderer.setPreRevealImage(vm.readFileBinary(c.preRevealImage));
        token.setProvenanceHash(renderer.tableHash());
        token.setMaxLockSeconds(c.maxLockSeconds);
        if (c.operator != address(0)) token.setOperator(c.operator);
        if (c.transferValidator != address(0)) token.setTransferValidator(c.transferValidator);
        if (bytes(c.contractURI).length != 0) token.setContractURI(c.contractURI);
        // Minting needs the commitment; the target block is set by the contract when minting closes.
        if (c.revealCommitment != bytes32(0)) token.commitReveal(c.revealCommitment);

        // 3. SeaDrop: payout, fee recipient, the public stage, the drop URI.
        token.updateCreatorPayoutAddress(c.seaDrop, c.creatorPayout);
        token.updateAllowedFeeRecipient(c.seaDrop, c.feeRecipient, true);
        token.updatePublicDrop(
            c.seaDrop,
            PublicDrop({
                mintPrice: c.publicMintPrice,
                startTime: c.publicStart,
                endTime: c.publicEnd,
                maxTotalMintableByWallet: c.publicMaxPerWallet,
                feeBps: c.publicFeeBps,
                restrictFeeRecipients: c.restrictFeeRecipients
            })
        );
        if (bytes(c.dropURI).length != 0) token.updateDropURI(c.seaDrop, c.dropURI);
    }
}
