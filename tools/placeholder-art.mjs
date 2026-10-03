#!/usr/bin/env node
// Makes the rehearsal art from the real export without anyone drawing anything. The output has
// the real set's shape (categories, layers per category, colours per category, rows, the hide
// rules as they appear in the table) and none of its content: every pixel, colour and name is
// replaced, the rows are shuffled and the trait indices permuted. The layers are dense noise with
// no two horizontal neighbours the same colour, which is the worst case for tokenURI size and gas.
// Safe to commit and to put on a public chain.
//
//   node tools/placeholder-art.mjs <real export.json> --out deploy/art/rehearsal-genesis.json [--seed <text>] [--name "Rehearsal Set"]
import { writeFileSync, unlinkSync } from "node:fs";
import path from "node:path";
import { parseArgs, assertPrivatePath, fmt } from "./lib/cli.mjs";
import { loadArt, composite, rectCount, serialiseArt, NO_LAYER, layerUsage } from "./lib/artfile.mjs";
import { keccak256, keccak256Hex } from "./lib/keccak.mjs";

/** Deterministic random bytes from a seed text, so a rerun makes the same file. */
function rng(seed) {
  let counter = 0, pool = Buffer.alloc(0), at = 0;
  return () => {
    if (at >= pool.length) { pool = keccak256(Buffer.from(`${seed}:${counter++}`)); at = 0; }
    return pool[at++];
  };
}
const nextInt = (rand, n) => ((rand() << 16) | (rand() << 8) | rand()) % n;

export function scramble(art, { seed = "rehearsal", name = "Rehearsal Set" } = {}) {
  const rand = rng(seed);
  const n = art.categories.length;

  // Colours: the same count per category, none of the originals, distinct within the category.
  const categories = art.categories.map((cat, ci) => {
    const colours = [];
    const seen = new Set();
    while (colours.length < cat.colours) {
      const c = [rand(), rand(), rand()];
      const key = c.join(",");
      if (seen.has(key)) continue;
      seen.add(key); colours.push(c);
    }
    const layers = cat.layers.length;
    const blob = Buffer.alloc(1 + 3 * cat.colours + layers * 256);
    blob[0] = cat.colours;
    colours.forEach((c, i) => { blob[1 + 3 * i] = c[0]; blob[2 + 3 * i] = c[1]; blob[3 + 3 * i] = c[2]; });
    const start = 1 + 3 * cat.colours;
    for (let l = 0; l < layers; ++l) {
      const salt = nextInt(rand, 1 << 20);
      for (let p = 0; p < 256; ++p) {
        // Cycling through the colour table means horizontal neighbours never match, so every
        // pixel starts a new rect. With one colour, alternate paint and gap instead.
        blob[start + l * 256 + p] = cat.colours >= 2 ? 1 + ((p + salt) % cat.colours) : ((p + (p >> 4) + salt) % 2 === 0 ? 1 : 0);
      }
    }
    const names = Array.from({ length: layers }, (_, l) => `Set ${ci + 1} Layer ${l + 1}`);
    return { name: `Set ${ci + 1}`, layers: names, blob: "0x" + blob.toString("hex") };
  });

  // Table: rows shuffled, trait indices permuted per category, hidden cells kept where they are
  // in each row, so rule shapes and rarity histograms survive but nothing maps back.
  const order = Array.from({ length: art.rows }, (_, i) => i);
  for (let i = order.length - 1; i > 0; --i) { const j = nextInt(rand, i + 1); [order[i], order[j]] = [order[j], order[i]]; }
  const perms = art.categories.map((cat) => {
    const p = Array.from({ length: cat.layers.length }, (_, i) => i);
    for (let i = p.length - 1; i > 0; --i) { const j = nextInt(rand, i + 1); [p[i], p[j]] = [p[j], p[i]]; }
    return p;
  });
  const table = Buffer.alloc(art.rows * n);
  for (let r = 0; r < art.rows; ++r) for (let ci = 0; ci < n; ++ci) {
    const v = art.table[order[r] * n + ci];
    table[r * n + ci] = v === NO_LAYER ? NO_LAYER : perms[ci][v];
  }

  const raw = {
    format: "nightfall-onchain-art",
    version: 1,
    collection: name,
    source: { width: art.raw.source?.width ?? 16 * (art.factor || 1), height: art.raw.source?.height ?? 16 * (art.factor || 1), factor: art.factor ?? 1, traitForgeSeed: "rehearsal", supply: art.rows },
    categories,
    rows: art.rows,
    table: "0x" + table.toString("hex"),
    provenanceHash: keccak256Hex(table),
    samples: [],
  };
  return raw;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const [inPath] = args._;
  if (!inPath || !args.out) {
    console.error('usage: node tools/placeholder-art.mjs <real export.json> --out <rehearsal.json> [--seed <text>] [--name "Rehearsal Set"] [--allow-tracked]');
    process.exit(2);
  }
  assertPrivatePath(inPath, "real export", Boolean(args["allow-tracked"]));
  const art = loadArt(inPath);
  const raw = scramble(art, { seed: args.seed ?? "rehearsal", name: args.name ?? "Rehearsal Set" });

  // Samples on Trait Forge's rows (first, last, every 37th) inside the JSON, and the picture of
  // every row in <out>.pixels.bin, both from the independent compositor, so `run` and `runFull`
  // of VerifyExport both work on it.
  const tmpPath = args.out + ".tmp";
  writeFileSync(tmpPath, serialiseArt(raw));
  const made = loadArt(tmpPath);
  let rectMin = Infinity, rectMax = 0;
  const fullPixels = Buffer.alloc(made.rows * 1024);
  raw.samples = [];
  for (let r = 0; r < made.rows; ++r) {
    const px = composite(made, r);
    px.copy(fullPixels, r * 1024);
    const rects = rectCount(px);
    rectMin = Math.min(rectMin, rects); rectMax = Math.max(rectMax, rects);
    if (r === 0 || r === made.rows - 1 || r % 37 === 0) raw.samples.push({ row: r, pixels: "0x" + px.toString("hex") });
  }
  writeFileSync(args.out, serialiseArt(raw));
  const pixelsPath = args.out.replace(/\.json$/, "") + ".pixels.bin";
  writeFileSync(pixelsPath, fullPixels);
  try { unlinkSync(tmpPath); } catch {}

  console.log(`rehearsal export ${args.out}`);
  console.log(`pixels file      ${pixelsPath} (every row, for the full check; not committed)`);
  console.log(`rows             ${made.rows}, categories ${made.categories.length}`);
  for (const u of layerUsage(made)) {
    const cat = made.categories.find((c) => c.name === u.category);
    console.log(`  ${u.category}: ${cat.layers.length} layers, ${cat.colours} colours, hidden on ${u.hidden} rows`);
  }
  console.log(`svg rects        min ${rectMin}, max ${rectMax} per token (256 is the ceiling; this set is built to sit at it)`);
  console.log(`provenance hash  ${raw.provenanceHash}`);
  console.log(`bytes on chain   ${fmt(raw.categories.reduce((s, c) => s + (c.blob.length - 2) / 2, 0))} of layer sets, ${fmt(made.rows * made.categories.length)} of table`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === new URL(import.meta.url).pathname) main();
