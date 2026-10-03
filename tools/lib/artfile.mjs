// Reads Trait Forge's "Export for on-chain" file (format nightfall-onchain-art, version 1) and
// composites tokens from it the way NightfallRenderer does, written independently of both the
// tool and the contract so the three can be compared.
import { readFileSync } from "node:fs";
import { keccak256Hex } from "./keccak.mjs";

export const NO_LAYER = 0xff;
const hex = (s) => Buffer.from(s.replace(/^0x/, ""), "hex");

/** Parse and structurally validate an export. Throws with a clear message on anything off. */
export function loadArt(path) {
  const a = JSON.parse(readFileSync(path, "utf8"));
  if (a.format !== "nightfall-onchain-art") throw new Error(`${path}: not a nightfall-onchain-art file`);
  if (a.version !== 1) throw new Error(`${path}: unsupported version ${a.version}`);
  if (!Array.isArray(a.categories) || a.categories.length === 0) throw new Error(`${path}: no categories`);
  const table = hex(a.table);
  if (table.length !== a.rows * a.categories.length) throw new Error(`${path}: table is ${table.length} bytes, expected rows x categories = ${a.rows * a.categories.length}`);
  const hash = keccak256Hex(table);
  if (hash !== a.provenanceHash.toLowerCase()) throw new Error(`${path}: provenanceHash ${a.provenanceHash} does not match keccak256(table) ${hash}`);
  const categories = a.categories.map((c, ci) => {
    const blob = hex(c.blob);
    const colours = blob[0];
    if (colours === 0) throw new Error(`category ${c.name}: zero colours`);
    const start = 1 + 3 * colours;
    if (blob.length <= start || (blob.length - start) % 256 !== 0) throw new Error(`category ${c.name}: malformed blob (${blob.length} bytes)`);
    const layers = (blob.length - start) / 256;
    if (layers !== c.layers.length) throw new Error(`category ${c.name}: ${layers} layers in the blob but ${c.layers.length} names`);
    for (let l = 0; l < layers; ++l) for (let p = 0; p < 256; ++p) {
      const v = blob[start + l * 256 + p];
      if (v > colours) throw new Error(`category ${c.name}, layer ${c.layers[l]}: pixel ${p} indexes colour ${v} of ${colours}`);
    }
    for (let r = 0; r < a.rows; ++r) {
      const v = table[r * a.categories.length + ci];
      if (v !== NO_LAYER && v >= layers) throw new Error(`row ${r}: category ${c.name} layer ${v} out of range (${layers} layers)`);
    }
    return { name: c.name, layers: c.layers, blob, colours, start };
  });
  const samples = (a.samples || []).map((s) => ({ row: s.row, pixels: hex(s.pixels) }));
  return { raw: a, collection: a.collection, factor: a.source?.factor, rows: a.rows, table, provenanceHash: hash, categories, samples };
}

/** Colour n (1-based) of a category as [r, g, b]. */
export function colourOf(cat, n) {
  const at = 1 + 3 * (n - 1);
  return [cat.blob[at], cat.blob[at + 1], cat.blob[at + 2]];
}

/** Composite one table row the renderer's way: 256 RGBA quads, alpha 0 or 255, tier border last. */
export function composite(art, row, tier = 0, tierColours = []) {
  const out = Buffer.alloc(1024);
  const n = art.categories.length;
  for (let ci = 0; ci < n; ++ci) {
    const layer = art.table[row * n + ci];
    if (layer === NO_LAYER) continue;
    const cat = art.categories[ci];
    const base = cat.start + layer * 256;
    for (let p = 0; p < 256; ++p) {
      const v = cat.blob[base + p];
      if (v === 0) continue;
      const [r, g, b] = colourOf(cat, v);
      out[p * 4] = r; out[p * 4 + 1] = g; out[p * 4 + 2] = b; out[p * 4 + 3] = 255;
    }
  }
  if (tier !== 0 && tier <= tierColours.length) {
    const c = tierColours[tier - 1];
    const paint = (p) => { out[p * 4] = (c >> 16) & 0xff; out[p * 4 + 1] = (c >> 8) & 0xff; out[p * 4 + 2] = c & 0xff; out[p * 4 + 3] = 255; };
    for (let i = 0; i < 16; ++i) { paint(i); paint(240 + i); paint(i * 16); paint(i * 16 + 15); }
  }
  return out;
}

/** How often each layer of each category appears in the table. */
export function layerUsage(art) {
  const n = art.categories.length;
  return art.categories.map((cat, ci) => {
    const counts = new Array(cat.layers.length).fill(0);
    let hidden = 0;
    for (let r = 0; r < art.rows; ++r) {
      const v = art.table[r * n + ci];
      if (v === NO_LAYER) ++hidden; else ++counts[v];
    }
    return { category: cat.name, counts, hidden };
  });
}

/** Every exported trait the table never uses: the rare trait a 555 run missed. */
export function missingTraits(art) {
  const out = [];
  for (const u of layerUsage(art)) {
    const cat = art.categories.find((c) => c.name === u.category);
    u.counts.forEach((count, l) => { if (count === 0) out.push({ category: u.category, trait: cat.layers[l], index: l }); });
  }
  return out;
}

/** The number of <rect> elements the renderer's SVG would hold for a composited image. */
export function rectCount(pixels) {
  let rects = 0;
  for (let y = 0; y < 16; ++y) {
    let x = 0;
    while (x < 16) {
      const i = (y * 16 + x) * 4;
      if (pixels[i + 3] === 0) { ++x; continue; }
      let w = 1;
      while (x + w < 16) {
        const j = (y * 16 + x + w) * 4;
        if (pixels[j + 3] === 0 || pixels[j] !== pixels[i] || pixels[j + 1] !== pixels[i + 1] || pixels[j + 2] !== pixels[i + 2]) break;
        ++w;
      }
      ++rects; x += w;
    }
  }
  return rects;
}

/** Write an export object back out in the tool's own key order and hex style. */
export function serialiseArt(raw) {
  return JSON.stringify(raw, null, 1) + "\n";
}
