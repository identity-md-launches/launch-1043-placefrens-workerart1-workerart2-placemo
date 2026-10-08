// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {WorkerArt1, WorkerArt2} from "../src/art/WorkerArt.sol";
import {WorkerArtIndex} from "../src/art/WorkerArtIndex.sol";
import {WorkerFrensRenderer} from "../src/frens/WorkerFrensRenderer.sol";
import {FrensRules} from "./frens/FrensRules.sol";

/// @dev The renderer with its art reads open
contract ArtProbe is WorkerFrensRenderer {
    constructor(address a1, address a2) WorkerFrensRenderer(a1, a2) {}

    function entry(uint256 i) external view returns (bytes memory) {
        return _entry(i);
    }
}

/// @notice The new art as the launch puts it on chain: framed so every byte is PUSH data, hashed into the renderer's
///         index, indexed inside the chunks, well formed for the renderer's drawing loop; and the renderer's failure
///         paths over it (a missing entry, an unknown background, a character that is none, the swarm's chunks absent).
contract FrensArtFramingTest is Test, FrensRules {
    address art1;
    address art2;
    ArtProbe r;

    function setUp() public {
        art1 = address(new WorkerArt1());
        art2 = address(new WorkerArt2());
        r = new ArtProbe(art1, art2);
    }

    /* ── the chunks' code ──────────────────────────────────────── */

    /// @dev A chunk's code is a STOP, then frames of 33 bytes: a PUSH32 before every 32 bytes of art. Read as
    ///      instructions it is nothing but STOP and PUSH32s: IMD's scan can't find an opcode in the art.
    function test_ChunksAreFramedPushData() public {
        address[2] memory chunks = [art1, art2];
        for (uint256 c; c < 2; ++c) {
            bytes memory code = chunks[c].code;
            assertEq(uint8(code[0]), 0x00, "a STOP first: calling it does nothing");
            assertEq((code.length - 1) % 33, 0, "whole frames");
            uint256 frames = (code.length - 1) / 33;
            assertGt(frames, 0);
            for (uint256 k; k < frames; ++k) {
                assertEq(uint8(code[1 + 33 * k]), 0x7f, "PUSH32 before every 32 bytes");
            }
            // as instructions: only STOP and PUSH32
            for (uint256 i; i < code.length; ++i) {
                uint8 op = uint8(code[i]);
                assertTrue(op == 0x00 || op == 0x7f, "an instruction in the art");
                if (op == 0x7f) i += 32;
            }
            assertTrue((WorkerArtIndex.FRAMED >> (7 + c)) & 1 == 1, "the index knows it is framed");
        }
        assertEq(art1.code.length, 1 + 33 * 707, "707 frames: 22618 bytes of art");
        (bool ok, bytes memory ret) = art1.call("");
        assertTrue(ok && ret.length == 0, "calling a chunk does nothing");
    }

    /// @dev The renderer's index names each chunk's code hash as hex text: the launch's chunks hash to entries 7 and 8
    function test_IndexHashesAreTheChunks() public view {
        bytes memory text = WorkerArtIndex.CHUNK_HASHES;
        assertEq(text.length, 64 * WorkerArtIndex.CHUNKS, "nine hashes");
        assertEq(_hex(text, 7 * 64, 64), uint256(art1.codehash), "WorkerArt1");
        assertEq(_hex(text, 8 * 64, 64), uint256(art2.codehash), "WorkerArt2");
        for (uint256 c; c < 7; ++c) {
            assertTrue(_hex(text, c * 64, 64) != 0, "the swarm's chunks have hashes");
        }
        // the text is text: IMD's scan reads it as PUSH data or as printable bytes, never as an escape opcode
        for (uint256 i; i < text.length; ++i) {
            uint8 b = uint8(text[i]);
            assertTrue((b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66), "lowercase hex");
        }
    }

    /// @dev Every index entry points inside its chunk; the launch's entries are the coat, item06, the backgrounds and
    ///      the palettes, and only those; everything else is the swarm's
    function test_IndexPointsInsideTheChunks() public view {
        bytes memory ix = WorkerArtIndex.INDEX;
        assertEq(ix.length, 10 * WorkerArtIndex.ENTRIES, "five bytes an entry, as hex");
        uint256[2] memory artBytes = [(art1.code.length - 1) / 33 * 32, (art2.code.length - 1) / 33 * 32];
        for (uint256 i; i < WorkerArtIndex.ENTRIES; ++i) {
            uint256 c = _hex(ix, i * 10, 2);
            uint256 off = _hex(ix, i * 10 + 2, 4);
            uint256 len = _hex(ix, i * 10 + 6, 4);
            assertLt(c, WorkerArtIndex.CHUNKS, "a chunk that exists");
            assertGt(len, 0, "an entry with bytes");
            bool launchEntry = i == WorkerArtIndex.COAT || i == WorkerArtIndex.ITEM0 + 5
                || (i >= WorkerArtIndex.BG0 && i < WorkerArtIndex.BG0 + 12) || i >= WorkerArtIndex.PALETTE;
            assertEq(c >= 7, launchEntry, "the launch's art is exactly the coat, item06, the backgrounds, the palettes");
            if (c >= 7) assertLe(off + len, artBytes[c - 7], "inside the chunk's art");
        }
        assertEq(WorkerArtIndex.PENDING_BG, 7, "an unrevealed fren sits in front of the green tube");
    }

    /// @dev Every layer the launch deploys is well formed for the renderer's drawing loop: a 4-byte header, then
    ///      exactly h rows of runs that each cover exactly w pixels, and nothing after the last row
    function test_LaunchLayersAreWellFormed() public view {
        uint256[14] memory layers;
        layers[0] = WorkerArtIndex.COAT;
        layers[1] = WorkerArtIndex.ITEM0 + 5;
        for (uint256 b; b < 12; ++b) {
            layers[2 + b] = WorkerArtIndex.BG0 + b;
        }
        for (uint256 k; k < layers.length; ++k) {
            bytes memory d = r.entry(layers[k]);
            uint256 w = uint8(d[2]);
            uint256 h = uint8(d[3]);
            assertTrue(w > 0 && h > 0, "a layer with size");
            assertLe(uint256(uint8(d[0])) + w, 120, "inside the 120x120 space");
            assertLe(uint256(uint8(d[1])) + h, 120, "inside the 120x120 space");
            uint256 i = 4;
            for (uint256 y; y < h; ++y) {
                uint256 x;
                while (x < w) {
                    assertLe(i + 2, d.length, "a row ends early");
                    uint256 n = uint8(d[i]);
                    assertGt(n, 0, "an empty run");
                    x += n;
                    i += 2;
                }
                assertEq(x, w, "a row covers exactly its width");
            }
            assertEq(i, d.length, "nothing after the last row");
            if (k >= 2) assertTrue(w >= 84 && h >= 84, "a background covers the canvas");
        }
    }

    /// @dev The palettes: the shared one holds exactly the shared entries, each background's own fits after them, and
    ///      every background's 256-colour palette starts with the same shared colours
    function test_PalettesFitTogether() public view {
        bytes memory shared = r.entry(WorkerArtIndex.PALETTE);
        assertEq(shared.length, 4 * WorkerArtIndex.SHARED, "145 shared colours, BGR0");
        bytes memory first = r.palette(0);
        for (uint256 b; b < 12; ++b) {
            bytes memory own = r.entry(WorkerArtIndex.BGPAL0 + b);
            assertEq(own.length % 4, 0);
            assertLe(4 * (WorkerArtIndex.SHARED + 1) + own.length, 1024, "fits after the shared colours");
            bytes memory pal = r.palette(b);
            assertEq(pal.length, 1024);
            for (uint256 i; i < 4; ++i) {
                assertEq(uint8(pal[i]), 0, "index 0 unused");
            }
            for (uint256 i = 4; i < 4 * (WorkerArtIndex.SHARED + 1); ++i) {
                assertEq(pal[i], first[i], "the same shared colours");
            }
            for (uint256 i; i < own.length; ++i) {
                assertEq(pal[4 * (WorkerArtIndex.SHARED + 1) + i], own[i], "then its own");
            }
        }
    }

    /* ── failure paths ─────────────────────────────────────────── */

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_EntryPastTheIndexIsMissing(uint256 i) public {
        i = bound(i, WorkerArtIndex.ENTRIES, type(uint256).max);
        vm.expectRevert(WorkerFrensRenderer.Missing.selector);
        r.entry(i);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_UnknownBackgroundIsMissing(uint256 bg) public {
        bg = bound(bg, 12, type(uint256).max);
        vm.expectRevert(WorkerFrensRenderer.Missing.selector);
        r.palette(bg);
        uint24 combo = uint24((bg % 16 < 12 ? 12 : bg % 16) << 15); // backgrounds 12..15 fit the 4 bits, none exists
        vm.expectRevert(WorkerFrensRenderer.Missing.selector);
        r.canvas(combo, 0);
        vm.expectRevert(WorkerFrensRenderer.Missing.selector);
        r.bmp(combo, 0);
    }

    /// @dev A character that is none (3), a face past the 13, a coat or shirt past theirs, a hat past the 2: the
    ///      drawing stops (after the background, before any swarm read)
    function test_NoSuchFrenIsMissing() public {
        uint24[5] memory bad = [uint24(3), uint24(13 << 2), uint24(3 << 8), uint24(6 << 10), uint24(3 << 13)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(WorkerFrensRenderer.Missing.selector);
            r.canvas(bad[i], 1);
        }
    }

    /// @dev Without the swarm's chunks (this chain has none) a fren draws nothing: the first face read fails on the
    ///      chunk's hash, never on garbage. The new layers alone read fine.
    function test_WithoutTheSwarmNothingDraws() public {
        vm.expectRevert(WorkerFrensRenderer.BadArt.selector);
        r.canvas(0, 0);
        vm.expectRevert(WorkerFrensRenderer.BadArt.selector);
        r.unrevealed(1);
        vm.expectRevert(WorkerFrensRenderer.BadArt.selector);
        r.tokenURI(1, 0, 1);
        vm.expectRevert(WorkerFrensRenderer.BadArt.selector);
        r.pendingURI(1);
        assertGt(r.entry(WorkerArtIndex.COAT).length, 0);
        // every swarm entry: the 39 faces, the 2 hats, the 14 items that aren't item06
        for (uint256 i; i < WorkerArtIndex.BG0; ++i) {
            if (i == WorkerArtIndex.COAT || i == WorkerArtIndex.ITEM0 + 5) continue;
            vm.expectRevert(WorkerFrensRenderer.BadArt.selector);
            r.entry(i);
        }
    }

    /// @dev A chunk's code replaced by anything else (even one byte off) draws nothing
    function test_ATamperedChunkDrawsNothing() public {
        bytes memory code = art2.code;
        code[code.length - 1] = bytes1(uint8(code[code.length - 1]) ^ 1);
        vm.etch(art2, code);
        vm.expectRevert(WorkerFrensRenderer.BadArt.selector);
        r.palette(0);
        vm.etch(art2, "");
        vm.expectRevert(WorkerFrensRenderer.BadArt.selector);
        r.palette(0);
    }

    /* ── the names ─────────────────────────────────────────────── */

    /// @dev Every value of every trait has a name, and the twelve backgrounds are the launch's
    function test_EveryValueHasAName() public view {
        string[12] memory bgs = [
            "Clean Lab Blue",
            "Clean Lab Green",
            "Clean Lab Red",
            "Messy Lab Blue",
            "Messy Lab Green",
            "Messy Lab Red",
            "Tube Blue",
            "Tube Green",
            "Tube Red",
            "Tube Yellow",
            "Wireframe Green",
            "Wireframe Red"
        ];
        for (uint256 b; b < 12; ++b) {
            assertEq(_trait(r.attributes(uint24(b << 15)), "Background"), bgs[b]);
        }
        uint8[8] memory values = [3, 13, 4, 3, 6, 3, 12, 16];
        uint8[8] memory shifts = [0, 2, 6, 8, 10, 13, 15, 19];
        string[8] memory traits = ["Character", "Face", "Eye", "Coat", "Shirt", "Hat", "Background", "Item"];
        for (uint256 t; t < 8; ++t) {
            for (uint256 v; v < values[t]; ++v) {
                string memory name = _trait(r.attributes(uint24(v << shifts[t])), traits[t]);
                assertGt(bytes(name).length, 0, "a name");
            }
        }
        assertEq(_trait(r.attributes(_combo(BOBO, LASER, 3, GOLD, 5, 2, 11, 15)), "Item"), "Bunsen Burner");
        assertEq(_trait(r.attributes(_combo(MUMU, 0, 0, 0, 0, 1, 0, SABER)), "Item"), "Green Lightsaber");
        assertEq(_trait(r.attributes(_combo(MUMU, 0, 0, 0, 0, 1, 0, SABER)), "Hat"), "Mumu Hat");
    }

    /// @dev attributes() names what it is given and checks nothing: a value past its trait gets no name. The
    ///      collection's check() refuses such a combo before it can ever be revealed, so no token carries one.
    function test_AttributesDoNotValidate() public view {
        assertEq(_trait(r.attributes(uint24(3 << 13)), "Hat"), "");
        assertEq(_trait(r.attributes(uint24(3)), "Character"), "");
        assertEq(_trait(r.attributes(uint24(13 << 2)), "Face"), "");
    }

    function _trait(string memory json, string memory trait) internal pure returns (string memory) {
        bytes memory a = bytes(json);
        bytes memory key = bytes(string.concat('"', trait, '","value":"'));
        uint256 s = type(uint256).max;
        for (uint256 i; i + key.length <= a.length; ++i) {
            bool ok = true;
            for (uint256 k; k < key.length && ok; ++k) {
                ok = a[i + k] == key[k];
            }
            if (ok) {
                s = i + key.length;
                break;
            }
        }
        require(s != type(uint256).max, "trait not in the attributes");
        uint256 e = s;
        while (a[e] != '"') ++e;
        bytes memory out = new bytes(e - s);
        for (uint256 i; i < out.length; ++i) {
            out[i] = a[s + i];
        }
        return string(out);
    }

    function _hex(bytes memory text, uint256 at, uint256 n) internal pure returns (uint256 v) {
        for (uint256 k; k < n; ++k) {
            uint256 d = uint8(text[at + k]);
            v = v << 4 | (d < 0x3a ? d - 0x30 : d - 0x57);
        }
    }
}
