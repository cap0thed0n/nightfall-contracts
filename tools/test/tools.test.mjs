// node --test tools/test/  (from contracts/). Covers the libraries and both command-line tools,
// end to end, on the committed fixture and on temporary files outside the repository.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, copyFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { keccak256Hex } from "../lib/keccak.mjs";
import { decodePng, encodePng, reduceTo16, upscale16 } from "../lib/png.mjs";
import { loadArt, composite, missingTraits, layerUsage, rectCount, serialiseArt, NO_LAYER } from "../lib/artfile.mjs";
import { scramble } from "../placeholder-art.mjs";

const here = path.dirname(new URL(import.meta.url).pathname);
const contracts = path.resolve(here, "../..");
const fixture = path.join(contracts, "deploy/art/fixture-genesis.json");
const run = (script, args) => spawnSync(process.execPath, [path.join(contracts, "tools", script), ...args], { encoding: "utf8" });

test("keccak256 matches the reference vectors", () => {
  assert.equal(keccak256Hex(Buffer.alloc(0)), "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470");
  assert.equal(keccak256Hex(Buffer.from("abc")), "0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45");
  // Two blocks: 200 bytes of 0x07, checked against cast keccak.
  assert.equal(keccak256Hex(Buffer.alloc(200, 7)), "0x4143ef737e81b990c8b604140712d1b0667457ad90b65918a9fa319d00c5b361");
});

test("PNG encode, decode and reduce round-trip; dirty upscales are refused", () => {
  const px = Buffer.alloc(1024);
  for (let p = 0; p < 256; ++p) {
    if ((p * 7) % 3 === 0) continue; // transparent
    px[p * 4] = p; px[p * 4 + 1] = 255 - p; px[p * 4 + 2] = (p * 13) & 0xff; px[p * 4 + 3] = 255;
  }
  const big = upscale16(px, 5);
  const img = decodePng(encodePng(80, 80, big));
  assert.equal(img.width, 80);
  const reduced = reduceTo16(img, "t");
  assert.equal(reduced.factor, 5);
  assert.ok(reduced.pixels.equals(px));
  // one stray pixel inside a block
  const dirty = Buffer.from(big); dirty[(2 * 80 + 6) * 4] ^= 0xff; // inside opaque block (1, 0)
  assert.throws(() => reduceTo16(decodePng(encodePng(80, 80, dirty)), "t"), /not one solid colour/);
  // soft alpha
  // block (1, 0) is opaque; give all 25 of its pixels a half alpha
  const soft = Buffer.from(big); for (let dy = 0; dy < 5; ++dy) for (let dx = 0; dx < 5; ++dx) soft[(dy * 80 + 5 + dx) * 4 + 3] = 128;
  assert.throws(() => reduceTo16(decodePng(encodePng(80, 80, soft)), "t"), /soft alpha|not one solid/);
  // not a multiple of 16
  assert.throws(() => reduceTo16({ width: 70, height: 70, rgba: Buffer.alloc(70 * 70 * 4) }, "t"), /multiple of 16/);
});

test("the independent compositor draws the fixture exactly as Trait Forge did", () => {
  const art = loadArt(fixture);
  assert.equal(art.rows, 555);
  assert.equal(art.samples.length, 16);
  for (const s of art.samples) assert.ok(composite(art, s.row).equals(s.pixels), `row ${s.row}`);
  assert.deepEqual(missingTraits(art), []);
  assert.ok(rectCount(composite(art, 0)) > 0);
});

test("a trait the table never uses is reported by name", () => {
  const art = loadArt(fixture);
  const n = art.categories.length;
  // Move every use of Headwear layer 1 onto layer 0.
  const t = Buffer.from(art.table);
  for (let r = 0; r < art.rows; ++r) if (t[r * n + 5] === 1) t[r * n + 5] = 0;
  const raw = { ...art.raw, table: "0x" + t.toString("hex"), provenanceHash: keccak256Hex(t) };
  const dir = mkdtempSync(path.join(tmpdir(), "nf-"));
  const p = path.join(dir, "x.json");
  writeFileSync(p, serialiseArt(raw));
  const missing = missingTraits(loadArt(p));
  assert.equal(missing.length, 1);
  assert.equal(missing[0].category, "Headwear");
  assert.equal(missing[0].trait, art.categories[5].layers[1]);
  rmSync(dir, { recursive: true });
});

test("loadArt refuses a wrong provenance hash and a bad table size", () => {
  const art = loadArt(fixture);
  const dir = mkdtempSync(path.join(tmpdir(), "nf-"));
  const p = path.join(dir, "x.json");
  writeFileSync(p, serialiseArt({ ...art.raw, provenanceHash: "0x" + "00".repeat(32) }));
  assert.throws(() => loadArt(p), /provenanceHash/);
  writeFileSync(p, serialiseArt({ ...art.raw, rows: 554 }));
  assert.throws(() => loadArt(p), /table is/);
  rmSync(dir, { recursive: true });
});

test("art-check passes on matching PNGs, writes the pixels file, and fails loudly on a changed pixel", () => {
  const art = loadArt(fixture);
  const dir = mkdtempSync(path.join(tmpdir(), "nf-"));
  const exp = path.join(dir, "genesis.json");
  copyFileSync(fixture, exp);
  const pngs = path.join(dir, "tokens");
  mkdirSync(pngs);
  // Trait Forge with metadata off: <slug>-0001.png, and the slug carries digits of its own.
  for (let r = 0; r < art.rows; ++r) {
    writeFileSync(path.join(pngs, `night-2026-${String(r + 1).padStart(4, "0")}.png`), encodePng(64, 64, upscale16(composite(art, r), 4)));
  }
  let res = run("art-check.mjs", [exp, pngs]);
  assert.equal(res.status, 0, res.stdout + res.stderr);
  assert.match(res.stdout, /555 of 555 rows match/);
  assert.match(res.stdout, /every exported trait appears/);
  assert.match(res.stdout, /RESULT\s+PASS|result\s+PASS/);
  const bin = path.join(dir, "genesis.pixels.bin");
  assert.equal(readFileSync(bin).length, 555 * 1024);
  assert.ok(readFileSync(bin).subarray(37 * 1024, 38 * 1024).equals(composite(art, 37)));
  // No pixel data in the summary.
  assert.ok(!/0x[0-9a-f]{64,}/.test(res.stdout.replace(/provenance hash\s+0x[0-9a-f]{64}/, "")));

  // Trait Forge with metadata on: an images/ subfolder with 1.png, 2.png; the tool follows it.
  rmSync(bin);
  rmSync(pngs, { recursive: true });
  const zipRoot = path.join(dir, "export");
  mkdirSync(path.join(zipRoot, "images"), { recursive: true });
  writeFileSync(path.join(zipRoot, "metadata.json"), "{}");
  for (let r = 0; r < art.rows; ++r) {
    writeFileSync(path.join(zipRoot, "images", `${r + 1}.png`), encodePng(64, 64, upscale16(composite(art, r), 4)));
  }
  res = run("art-check.mjs", [exp, zipRoot]);
  assert.equal(res.status, 0, res.stdout + res.stderr);
  assert.match(res.stdout, /followed into the subfolder/);
  assert.match(res.stdout, /555 of 555 rows match/);
  const images = path.join(zipRoot, "images");

  // One pixel changed on token 200: named, and the pixels file is not written.
  rmSync(bin);
  const px = composite(art, 199); px[(5 * 16 + 9) * 4] ^= 0x40; px[(5 * 16 + 9) * 4 + 3] = 255;
  writeFileSync(path.join(images, `200.png`), encodePng(64, 64, upscale16(px, 4)));
  res = run("art-check.mjs", [exp, images]);
  assert.equal(res.status, 1);
  assert.match(res.stdout, /token 200 \(row 199\), first difference at pixel \(9, 5\)/);
  assert.ok(!existsSync(bin));

  // Wrong numbering hint.
  writeFileSync(path.join(images, `200.png`), encodePng(64, 64, upscale16(composite(art, 199), 4)));
  res = run("art-check.mjs", [exp, images, "--first-token", "0"]);
  assert.equal(res.status, 1);
  assert.match(res.stdout, /check --first-token/);

  // A missing token file.
  rmSync(path.join(images, `3.png`));
  res = run("art-check.mjs", [exp, images]);
  assert.equal(res.status, 1);
  assert.match(res.stdout, /no PNG for 1 token\(s\): 3/);
  rmSync(dir, { recursive: true });
});

test("art-check refuses inputs inside the repository that git does not ignore", () => {
  const res = run("art-check.mjs", [fixture, path.join(contracts, "deploy/art")]);
  assert.equal(res.status, 1);
  assert.match(res.stderr, /not git-ignored/);
});

test("the placeholder set keeps the shape and drops the content", () => {
  const art = loadArt(fixture);
  const raw = scramble(art, { seed: "test" });
  const dir = mkdtempSync(path.join(tmpdir(), "nf-"));
  const p = path.join(dir, "r.json");
  writeFileSync(p, serialiseArt(raw));
  const made = loadArt(p); // structurally valid, provenance hash consistent
  assert.equal(made.rows, art.rows);
  assert.equal(made.categories.length, art.categories.length);
  made.categories.forEach((c, i) => {
    assert.equal(c.layers.length, art.categories[i].layers.length);
    assert.equal(c.colours, art.categories[i].colours);
    assert.ok(!c.name.includes(art.categories[i].name));
    // Rarity histograms survive up to a permutation; hidden counts are identical.
    const a = layerUsage(art)[i], b = layerUsage(made)[i];
    assert.deepEqual([...a.counts].sort((x, y) => x - y), [...b.counts].sort((x, y) => x - y));
    assert.equal(a.hidden, b.hidden);
  });
  assert.notEqual(made.provenanceHash, art.provenanceHash);
  assert.notEqual(made.table.toString("hex"), art.table.toString("hex"));
  // Hide rules survive: wherever the original row hid a category, the shuffled row does too.
  const n = art.categories.length;
  const pattern = (t, r) => Array.from({ length: n }, (_, c) => t[r * n + c] === NO_LAYER ? 1 : 0).join("");
  const orig = new Map(); for (let r = 0; r < art.rows; ++r) orig.set(pattern(art.table, r), (orig.get(pattern(art.table, r)) ?? 0) + 1);
  const now = new Map(); for (let r = 0; r < made.rows; ++r) now.set(pattern(made.table, r), (now.get(pattern(made.table, r)) ?? 0) + 1);
  assert.deepEqual([...now.entries()].sort(), [...orig.entries()].sort());
  // Worst case: every row sits at the rect ceiling.
  for (let r = 0; r < made.rows; ++r) assert.equal(rectCount(composite(made, r)), 256);
  // No original colour survives.
  const origColours = new Set(art.categories.flatMap((c) => Array.from({ length: c.colours }, (_, i) => c.blob.subarray(1 + 3 * i, 4 + 3 * i).toString("hex"))));
  for (const c of made.categories) for (let i = 0; i < c.colours; ++i) assert.ok(!origColours.has(c.blob.subarray(1 + 3 * i, 4 + 3 * i).toString("hex")));
  // Deterministic.
  assert.equal(serialiseArt(scramble(art, { seed: "test" })), serialiseArt(raw));
  rmSync(dir, { recursive: true });
});

test("placeholder-art writes the export and the pixels file, and forge verifies both when available", () => {
  const dir = mkdtempSync(path.join(tmpdir(), "nf-"));
  const out = path.join(dir, "rehearsal.json");
  const res = run("placeholder-art.mjs", [fixture, "--out", out, "--allow-tracked"]);
  assert.equal(res.status, 0, res.stdout + res.stderr);
  assert.match(res.stdout, /min 256, max 256/);
  assert.equal(readFileSync(path.join(dir, "rehearsal.pixels.bin")).length, 555 * 1024);
  const made = loadArt(out);
  assert.ok(made.samples.length >= 16);
  for (const s of made.samples) assert.ok(composite(made, s.row).equals(s.pixels));
  rmSync(dir, { recursive: true });
});

// A cosmetic of your own: one 16 x 16 PNG becomes a layer set the renderer takes.
import { cosmeticBlob } from "../cosmetic-blob.mjs";

test("cosmetic-blob turns a clean upscale into one layer with its exact palette, and refuses soft edges", () => {
  const w = 32, rgba = Buffer.alloc(w * w * 4);
  for (let y = 0; y < w; y++) for (let x = 0; x < w; x++) {
    const X = Math.floor(x / 2), Y = Math.floor(y / 2), o = (y * w + x) * 4;
    if (Y === 6 && X >= 3 && X <= 12) { rgba[o] = 0x00; rgba[o + 1] = 0xe5; rgba[o + 2] = 0xff; rgba[o + 3] = 255; }
    if (Y === 5 && X === 3) { rgba[o] = 0x1a; rgba[o + 1] = 0x1a; rgba[o + 2] = 0x2e; rgba[o + 3] = 255; }
  }
  const dir = mkdtempSync(path.join(tmpdir(), "nf-cosmetic-"));
  const png = path.join(dir, "visor.png");
  writeFileSync(png, encodePng(w, w, rgba));
  const out = path.join(dir, "visor.json");
  const r = run("cosmetic-blob.mjs", [png, "--name", "Neon Visor", "--category", "Headwear", "--cap", "25", "--out", out]);
  assert.equal(r.status, 0, r.stderr);
  const file = JSON.parse(readFileSync(out, "utf8"));
  assert.equal(file.format, "nightfall-cosmetic");
  assert.deepEqual([file.name, file.category, file.cap, file.colours, file.source.factor], ["Neon Visor", "Headwear", 25, 2, 2]);
  const blob = Buffer.from(file.blob.slice(2), "hex");
  // One layer: the colour count, the palette in order of first use (top to bottom), then 256
  // pixel indices (0 transparent, 1 and 2 the colours).
  assert.equal(blob.length, 1 + 3 * 2 + 256);
  assert.equal(blob[0], 2);
  assert.deepEqual([...blob.subarray(1, 7)], [0x1a, 0x1a, 0x2e, 0x00, 0xe5, 0xff]);
  const px = blob.subarray(7);
  assert.equal(px[5 * 16 + 3], 1);
  assert.equal(px[6 * 16 + 3], 2);
  assert.equal(px.filter((v) => v !== 0).length, 11);
  // A numeric category stays a number.
  const r2 = run("cosmetic-blob.mjs", [png, "--name", "Neon Visor", "--category", "5", "--cap", "25", "--out", out]);
  assert.equal(r2.status, 0, r2.stderr);
  assert.equal(JSON.parse(readFileSync(out, "utf8")).category, 5);
  // Soft alpha is refused, as the art export refuses it.
  rgba[(6 * w + 6) * 4 + 3] = 128;
  writeFileSync(png, encodePng(w, w, rgba));
  const bad = run("cosmetic-blob.mjs", [png, "--name", "x", "--category", "5", "--cap", "1", "--out", out]);
  assert.notEqual(bad.status, 0);
  assert.match(bad.stderr, /soft alpha/);
  // An empty picture is refused.
  assert.throws(() => cosmeticBlob(Buffer.alloc(1024)), /empty/);
  rmSync(dir, { recursive: true, force: true });
});
