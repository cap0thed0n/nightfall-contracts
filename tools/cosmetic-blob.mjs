#!/usr/bin/env node
// A cosmetic of your own, from one 16 x 16 PNG, ready for the renderer.
//
//   node tools/cosmetic-blob.mjs <layer.png> --name "Neon Visor" --category Headwear --cap 100 [--out deploy/cosmetics/neon-visor.json]
//
// The PNG is the single layer of the cosmetic, on a transparent background, 16 x 16 or a clean
// integer upscale of it (32, 48, 64, ... pixels square, every block one solid colour), with every
// pixel either fully transparent or fully opaque, the same checks the art export runs. The colours
// used become the layer's exact palette (at most 255). The file written holds the name, the
// category, the supply cap and the layer set bytes the renderer takes, and
// `forge script script/TraitUpgrade.s.sol --sig "uploadFile(address,string)" <renderer> <file>` uploads it.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { parseArgs } from "./lib/cli.mjs";
import { decodePng, reduceTo16 } from "./lib/png.mjs";

export function cosmeticBlob(rgba16) {
  // The palette in order of first use; pixel values index it from 1, 0 is transparent.
  const colours = [];
  const index = new Map();
  const pixels = Buffer.alloc(256);
  for (let p = 0; p < 256; ++p) {
    const o = p * 4;
    if (rgba16[o + 3] === 0) continue;
    const key = (rgba16[o] << 16) | (rgba16[o + 1] << 8) | rgba16[o + 2];
    let i = index.get(key);
    if (i === undefined) {
      if (colours.length === 255) throw new Error("more than 255 colours");
      colours.push(key);
      i = colours.length;
      index.set(key, i);
    }
    pixels[p] = i;
  }
  if (colours.length === 0) throw new Error("the picture is empty: every pixel is transparent");
  const blob = Buffer.alloc(1 + 3 * colours.length + 256);
  blob[0] = colours.length;
  colours.forEach((c, i) => {
    blob[1 + 3 * i] = (c >> 16) & 0xff;
    blob[2 + 3 * i] = (c >> 8) & 0xff;
    blob[3 + 3 * i] = c & 0xff;
  });
  pixels.copy(blob, 1 + 3 * colours.length);
  return { blob, colours: colours.length, opaque: pixels.filter((v) => v !== 0).length };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const [pngPath] = args._;
  const name = args.name;
  const category = args.category;
  const cap = Number(args.cap);
  if (!pngPath || !name || category === undefined || !Number.isInteger(cap) || cap <= 0) {
    console.error('usage: node tools/cosmetic-blob.mjs <layer.png> --name "Neon Visor" --category Headwear --cap 100 [--out <file.json>]');
    process.exit(2);
  }
  const img = decodePng(readFileSync(pngPath));
  const { factor, pixels } = reduceTo16(img, path.basename(pngPath));
  const { blob, colours, opaque } = cosmeticBlob(pixels);
  const slug = String(name).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
  const out = args.out ?? path.join("deploy", "cosmetics", `${slug}.json`);
  mkdirSync(path.dirname(out), { recursive: true });
  const file = { format: "nightfall-cosmetic", version: 1, name: String(name), category: /^\d+$/.test(String(category)) ? Number(category) : String(category), cap, source: { file: path.basename(pngPath), factor }, colours, blob: `0x${blob.toString("hex")}` };
  writeFileSync(out, JSON.stringify(file, null, 2) + "\n");
  console.log(`cosmetic         ${name}`);
  console.log(`category         ${file.category}`);
  console.log(`supply cap       ${cap}`);
  console.log(`source           ${path.basename(pngPath)} (${img.width} px, ${factor}x of 16)`);
  console.log(`colours          ${colours}`);
  console.log(`opaque pixels    ${opaque} of 256`);
  console.log(`written          ${out}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === new URL(import.meta.url).pathname) main();
