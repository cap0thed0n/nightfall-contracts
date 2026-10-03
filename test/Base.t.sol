// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { SeaDrop } from "seadrop/SeaDrop.sol";
import { PublicDrop, MintParams, AllowListData } from "seadrop/lib/SeaDropStructs.sol";
import { ISeaDropTokenContractMetadata } from "seadrop/interfaces/ISeaDropTokenContractMetadata.sol";
import { NightfallGenesis } from "../src/NightfallGenesis.sol";
import { NightfallRenderer } from "../src/NightfallRenderer.sol";
import { PlaceholderArt } from "../src/art/PlaceholderArt.sol";

/// @notice A local SeaDrop, a Genesis token registered with it, a renderer loaded with the
///         placeholder set, and a public stage at price 0 with five per wallet, as testnet will be.
abstract contract BaseTest is Test {
    SeaDrop internal seadrop;
    NightfallGenesis internal token;
    NightfallRenderer internal renderer;

    address internal operator = makeAddr("operator");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal payout = makeAddr("payout");
    address internal royaltyReceiver = makeAddr("royaltyReceiver");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant MAX_SUPPLY = 555;
    uint96 internal constant ROYALTY_BPS = 650;
    uint64 internal constant MAX_LOCK = 26 hours;
    uint16 internal constant PER_WALLET = 5;
    uint256 internal constant START = 1_800_000_000;
    bytes32 internal constant TABLE_SEED = keccak256("placeholder table");
    bytes32 internal constant DEFAULT_SECRET = keccak256("the base test's reveal secret");
    bytes32 internal constant DEFAULT_COMMITMENT = keccak256(abi.encodePacked(DEFAULT_SECRET));

    function setUp() public virtual {
        vm.warp(START);
        vm.roll(1000);
        seadrop = new SeaDrop();
        address[] memory allowed = new address[](1);
        allowed[0] = address(seadrop);
        token = new NightfallGenesis("Nightfall Genesis", "NFG", allowed);
        token.setMaxSupply(MAX_SUPPLY);
        token.setRoyaltyInfo(ISeaDropTokenContractMetadata.RoyaltyInfo(royaltyReceiver, ROYALTY_BPS));
        token.setOperator(operator);
        token.setMaxLockSeconds(MAX_LOCK);
        token.updateCreatorPayoutAddress(address(seadrop), payout);
        token.updateAllowedFeeRecipient(address(seadrop), feeRecipient, true);
        token.updatePublicDrop(
            address(seadrop),
            PublicDrop({
                mintPrice: 0,
                startTime: uint48(block.timestamp),
                endTime: uint48(block.timestamp + 7 days),
                maxTotalMintableByWallet: PER_WALLET,
                feeBps: 0,
                restrictFeeRecipients: true
            })
        );

        renderer = new NightfallRenderer("Nightfall Genesis", "A boss of the network.");
        loadPlaceholders(renderer);
        renderer.setTable(PlaceholderArt.table(MAX_SUPPLY, TABLE_SEED));
        token.setRenderer(address(renderer));
        token.setProvenanceHash(renderer.tableHash());
        renderer.bindToken(address(token));
        // Minting needs the reveal committed first. Tests that need their own secret commit
        // again before the first mint.
        token.commitReveal(DEFAULT_COMMITMENT);
    }

    function loadPlaceholders(NightfallRenderer r) internal {
        string[] memory names = PlaceholderArt.categoryNames();
        for (uint256 i = 0; i < names.length; ++i) {
            r.addCategory(names[i], PlaceholderArt.category(i), PlaceholderArt.layerNames(i));
        }
    }

    function mintPublic(address to, uint256 quantity) internal {
        vm.prank(to);
        seadrop.mintPublic(address(token), feeRecipient, address(0), quantity);
    }

    function mintAll() internal {
        for (uint256 i = 0; i < MAX_SUPPLY / PER_WALLET; ++i) {
            mintPublic(address(uint160(0x1000 + i)), PER_WALLET);
        }
    }

    function stage(uint256 perWallet, uint256 stageSupply) internal view returns (MintParams memory) {
        return MintParams({
            mintPrice: 0,
            maxTotalMintableByWallet: perWallet,
            startTime: block.timestamp,
            endTime: block.timestamp + 1 days,
            dropStageIndex: 1,
            maxTokenSupplyForStage: stageSupply,
            feeBps: 0,
            restrictFeeRecipients: true
        });
    }

    function leaf(address minter, MintParams memory params) internal pure returns (bytes32) {
        return keccak256(abi.encode(minter, params));
    }

    /// @dev A two-leaf Merkle tree, hashed the way OpenZeppelin's MerkleProof sorts pairs.
    function root2(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function proofOf(bytes32 sibling) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = sibling;
    }

    function setAllowList(bytes32 root) internal {
        token.updateAllowList(address(seadrop), AllowListData(root, new string[](0), ""));
    }

    function mintAllowList(address minter, uint256 quantity, MintParams memory params, bytes32[] memory proof) internal {
        vm.prank(minter);
        seadrop.mintAllowList(address(token), feeRecipient, address(0), quantity, params, proof);
    }

    function startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(prefix);
        if (b.length > a.length) return false;
        for (uint256 i = 0; i < b.length; ++i) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    function contains(string memory s, string memory needle) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(needle);
        if (b.length > a.length) return false;
        for (uint256 i = 0; i + b.length <= a.length; ++i) {
            bool ok = true;
            for (uint256 j = 0; j < b.length; ++j) {
                if (a[i + j] != b[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    function count(string memory s, string memory needle) internal pure returns (uint256 n) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(needle);
        for (uint256 i = 0; i + b.length <= a.length; ++i) {
            bool ok = true;
            for (uint256 j = 0; j < b.length; ++j) {
                if (a[i + j] != b[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) ++n;
        }
    }
}
