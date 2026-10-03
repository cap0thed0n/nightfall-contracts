// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { console2 } from "forge-std/console2.sol";
import { Base64 } from "openzeppelin-contracts/utils/Base64.sol";
import { Strings } from "openzeppelin-contracts/utils/Strings.sol";
import { NightfallRenderer } from "../src/NightfallRenderer.sol";
import { PlaceholderArt } from "../src/art/PlaceholderArt.sol";
import { BaseTest } from "./Base.t.sol";

/// @notice The pre-reveal GIF: stored once as uploaded, served to every unrevealed token, never
///         touching a revealed one.
contract PreRevealTest is BaseTest {
    string internal constant GIF_PATH = "deploy/art/prereveal/pre-reveal160x.gif";
    /// keccak256 of the file as committed.
    bytes32 internal constant GIF_HASH = 0x4dd0219a743066acc197a1545822e69964c4c597f62076b84caa405373d44297;
    // The limits the art report holds every token to.
    uint256 internal constant GAS_LIMIT = 25_000_000;
    uint256 internal constant URI_LIMIT = 128 * 1024;

    bytes internal gif;
    uint256 internal storeGas;

    function setUp() public override {
        super.setUp();
        gif = vm.readFileBinary(GIF_PATH);
        uint256 before = gasleft();
        renderer.setPreRevealImage(gif);
        storeGas = before - gasleft();
    }

    // ---------------------------------------------------------------- the stored bytes

    function test_theFileIsTheOneUploaded() public {
        assertEq(gif.length, 21_704);
        assertEq(keccak256(gif), GIF_HASH);
    }

    function test_storedBytesMatchTheFileExactly() public {
        bytes memory stored = renderer.preRevealImage();
        assertEq(stored.length, gif.length);
        assertEq(keccak256(stored), GIF_HASH);
    }

    function test_theStoredGifIs160By160With30FramesOf200msLoopingForever() public {
        (uint256 w, uint256 h, uint256 frames, uint256 minDelay, uint256 maxDelay, bool loops, uint256 loopCount) = _walk(renderer.preRevealImage());
        assertEq(w, 160);
        assertEq(h, 160);
        assertEq(frames, 30);
        // GIF delays are in hundredths of a second: 20 is 200 ms, every frame.
        assertEq(minDelay, 20);
        assertEq(maxDelay, 20);
        assertTrue(loops);
        assertEq(loopCount, 0); // 0 means forever
    }

    // ---------------------------------------------------------------- the metadata

    function test_anUnrevealedTokenShowsTheGifAsItsImage() public {
        mintPublic(alice, 1);
        string memory image = string(abi.encodePacked("data:image/gif;base64,", Base64.encode(gif)));
        assertEq(string(renderer.unrevealedImage()), image);
        bytes memory json = abi.encodePacked(
            '{"name":"Nightfall Genesis #1","description":"A boss of the network.","image":"', image, '","attributes":[]}'
        );
        assertEq(token.tokenURI(1), string(abi.encodePacked("data:application/json;base64,", Base64.encode(json))));
    }

    function test_revealedTokensAreUnaffected() public {
        NightfallRenderer plain = new NightfallRenderer("Nightfall Genesis", "A boss of the network.");
        loadPlaceholders(plain);
        plain.setTable(PlaceholderArt.table(MAX_SUPPLY, TABLE_SEED));
        for (uint256 id = 1; id <= 5; ++id) {
            assertEq(renderer.tokenURI(id, true, 17, 0, ""), plain.tokenURI(id, true, 17, 0, ""));
            assertEq(renderer.tokenURI(id, true, 17, 2, ""), plain.tokenURI(id, true, 17, 2, ""));
        }
    }

    function test_withoutAGifTheFixedSvgStandsIn() public {
        NightfallRenderer plain = new NightfallRenderer("Nightfall Genesis", "A boss of the network.");
        assertEq(plain.preRevealImage().length, 0);
        assertEq(string(plain.unrevealedImage()), string(abi.encodePacked("data:image/svg+xml;base64,", Base64.encode(bytes(plain.unrevealedSvg())))));
    }

    // ---------------------------------------------------------------- the owner rules

    function test_onlyTheOwnerSetsIt() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        renderer.setPreRevealImage(gif);
    }

    function test_theOwnerCanReplaceItUntilTheFirstMint() public {
        bytes memory other = abi.encodePacked("GIF89a", new bytes(32));
        renderer.setPreRevealImage(other);
        assertEq(keccak256(renderer.preRevealImage()), keccak256(other));
        renderer.setPreRevealImage(gif);
        assertEq(keccak256(renderer.preRevealImage()), GIF_HASH);
    }

    function test_itIsFixedFromTheFirstMint() public {
        mintPublic(alice, 1);
        vm.expectRevert(NightfallRenderer.PreRevealFixed.selector);
        renderer.setPreRevealImage(abi.encodePacked("GIF89a", new bytes(32)));
        assertEq(keccak256(renderer.preRevealImage()), GIF_HASH);
    }

    function test_theArtFreezeNoLongerDecidesIt() public {
        renderer.freeze();
        bytes memory other = abi.encodePacked("GIF89a", new bytes(32));
        renderer.setPreRevealImage(other); // still before the first mint
        assertEq(keccak256(renderer.preRevealImage()), keccak256(other));
    }

    function test_itNeedsItsTokenBoundAndBindsOnce() public {
        NightfallRenderer loose = new NightfallRenderer("x", "y");
        vm.expectRevert(NightfallRenderer.TokenNotBound.selector);
        loose.setPreRevealImage(gif);
        vm.expectRevert(NightfallRenderer.TokenAlreadyBound.selector);
        renderer.bindToken(alice);
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        loose.bindToken(alice);
    }

    function test_refusesAnythingButAGif() public {
        vm.expectRevert(NightfallRenderer.NotAGif.selector);
        renderer.setPreRevealImage(hex"89504e470d0a1a0a"); // a PNG header
        vm.expectRevert(NightfallRenderer.NotAGif.selector);
        renderer.setPreRevealImage("GIF8");
    }

    function test_refusesAnImageTooLargeForOneStore() public {
        bytes memory big = abi.encodePacked("GIF89a", new bytes(24_570));
        vm.expectRevert(abi.encodeWithSelector(NightfallRenderer.ImageTooLarge.selector, 24_576, 24_575));
        renderer.setPreRevealImage(big);
    }

    // ---------------------------------------------------------------- measurements

    function test_measureStoringAndServingIt() public {
        mintPublic(alice, 1);
        uint256 before = gasleft();
        string memory uri = token.tokenURI(1);
        uint256 uriGas = before - gasleft();
        console2.log("store gas (setPreRevealImage)", storeGas);
        console2.log("unrevealed tokenURI gas     ", uriGas);
        console2.log("unrevealed tokenURI bytes   ", bytes(uri).length);
        assertLt(uriGas, GAS_LIMIT / 5);
        assertLt(bytes(uri).length, URI_LIMIT / 2);
        assertLt(storeGas, 6_000_000);
    }

    // ---------------------------------------------------------------- a GIF walker

    /// @dev Walks the GIF block by block: the screen size, every image descriptor, every
    ///      graphic control extension's delay, and the NETSCAPE2.0 loop block.
    function _walk(bytes memory b)
        internal
        pure
        returns (uint256 w, uint256 h, uint256 frames, uint256 minDelay, uint256 maxDelay, bool loops, uint256 loopCount)
    {
        require(b[0] == "G" && b[1] == "I" && b[2] == "F", "not a GIF");
        w = uint8(b[6]) | (uint256(uint8(b[7])) << 8);
        h = uint8(b[8]) | (uint256(uint8(b[9])) << 8);
        uint256 i = 13;
        uint8 flags = uint8(b[10]);
        if (flags & 0x80 != 0) i += 3 * (uint256(2) << (flags & 7));
        minDelay = type(uint256).max;
        while (true) {
            uint8 t = uint8(b[i]);
            if (t == 0x3B) break;
            if (t == 0x21) {
                uint8 label = uint8(b[i + 1]);
                if (label == 0xF9) {
                    uint256 d = uint8(b[i + 4]) | (uint256(uint8(b[i + 5])) << 8);
                    if (d < minDelay) minDelay = d;
                    if (d > maxDelay) maxDelay = d;
                } else if (label == 0xFF && _isNetscape(b, i + 3)) {
                    loops = true;
                    loopCount = uint8(b[i + 16]) | (uint256(uint8(b[i + 17])) << 8);
                }
                i = _skipSubBlocks(b, i + 2);
            } else if (t == 0x2C) {
                ++frames;
                uint8 f = uint8(b[i + 9]);
                i += 10;
                if (f & 0x80 != 0) i += 3 * (uint256(2) << (f & 7));
                i = _skipSubBlocks(b, i + 1); // past the LZW minimum code size
            } else {
                revert(string(abi.encodePacked("unknown block at ", Strings.toString(i))));
            }
        }
    }

    function _skipSubBlocks(bytes memory b, uint256 i) internal pure returns (uint256) {
        while (uint8(b[i]) != 0) i += uint256(uint8(b[i])) + 1;
        return i + 1;
    }

    function _isNetscape(bytes memory b, uint256 at) internal pure returns (bool) {
        bytes memory n = "NETSCAPE2.0";
        for (uint256 k = 0; k < n.length; ++k) if (b[at + k] != n[k]) return false;
        return true;
    }
}
