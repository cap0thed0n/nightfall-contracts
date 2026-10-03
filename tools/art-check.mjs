#!/usr/bin/env node
// The private full art check, step 1 of the art half. Runs on the deploying machine against the real files.
//
//   node tools/art-check.mjs <export.json> <folder of Trait Forge token PNGs> [--first-token 1]
//
// What it does, without ever printing a pixel:
//   1. refuses to run unless both inputs are git-ignored or outside the repository
//   2. validates the export's structure and its provenance hash
//   3. fails on any exported trait the table never uses (the rare trait a run missed), by name
//   4. reduces every token PNG to 16 x 16, refusing anything that is not a clean integer upscale
//   5. composites every row from the exported bytes with an independent compositor and compares
//      it with the PNG, pixel for pixel
//   6. writes <export>.pixels.bin, the 16 x 16 picture of every row taken from the PNGs, so
//      `forge script script/VerifyExport.s.sol --sig "runFull(string,string)" <export> <that file>`
//      proves all rows through the Solidity renderer as well
//   7. writes a summary (numbers only) to contracts/reports/ and prints it
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { parseArgs, assertPrivatePath, writeReport, fmt } from "./lib/cli.mjs";
import { loadArt, composite, missingTraits, layerUsage, rectCount } from "./lib/artfile.mjs";
import { decodePng, reduceTo16 } from "./lib/png.mjs";

function main() {
  const args = parseArgs(process.argv.slice(2));
  const [exportPath, pngDir] = args._;
  if (!exportPath || !pngDir) {
    console.error("usage: node tools/art-check.mjs <export.json> <png folder> [--first-token 1] [--out <pixels.bin>] [--allow-tracked]");
    process.exit(2);
  }
  const firstToken = Number(args["first-token"] ?? 1);
  const allowTracked = Boolean(args["allow-tracked"]);
  assertPrivatePath(exportPath, "export", allowTracked);
  assertPrivatePath(pngDir, "PNG folder", allowTracked);
  const outPath = args.out ?? exportPath.replace(/\.json$/, "") + ".pixels.bin";
  assertPrivatePath(path.dirname(outPath), "output folder", allowTracked);

  const lines = [];
  const say = (s) => { lines.push(s); console.log(s); };
  const problems = [];

  const art = loadArt(exportPath);
  say(`export           ${path.basename(exportPath)}`);
  say(`collection       ${art.collection}`);
  say(`rows             ${art.rows}`);
  say(`source factor    ${art.factor}`);
  say(`provenance hash  ${art.provenanceHash}`);
  say(`categories       ${art.categories.length}`);
  for (const u of layerUsage(art)) {
    const cat = art.categories.find((c) => c.name === u.category);
    say(`  ${u.category}: ${cat.layers.length} layers, ${cat.colours} colours, hidden on ${u.hidden} rows`);
  }

  // 3. Every trait must appear.
  const missing = missingTraits(art);
  if (missing.length) {
    say(`MISSING TRAITS   ${missing.length}: a trait with a share above 0 never appears in the table`);
    for (const m of missing) say(`  ${m.category} / ${m.trait}`);
    problems.push(`${missing.length} exported trait(s) never used; regenerate in Trait Forge until every trait appears`);
  } else say(`traits           every exported trait appears at least once`);

  // 4. The PNGs, one per token. Trait Forge writes images/1.png, images/2.png with metadata on,
  //    and <collection-slug>-0001.png with it off, so the token number is the last run of digits
  //    in the name (a slug may contain digits of its own), and a folder with no PNGs but an
  //    `images` subfolder is followed into it.
  let dir = pngDir;
  let files = readdirSync(dir).filter((f) => /\.png$/i.test(f));
  if (files.length === 0) {
    const sub = readdirSync(dir, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name);
    const images = sub.find((d) => d.toLowerCase() === "images") ?? sub.find((d) => readdirSync(path.join(dir, d)).some((f) => /\.png$/i.test(f)));
    if (images) { dir = path.join(dir, images); files = readdirSync(dir).filter((f) => /\.png$/i.test(f)); say(`png folder       ${dir} (followed into the subfolder)`); }
  }
  const byRow = new Map();
  const unnumbered = [];
  for (const f of files) {
    const m = f.replace(/\.png$/i, "").match(/(\d+)(?!.*\d)/);
    if (!m) { unnumbered.push(f); continue; }
    const row = Number(m[1]) - firstToken;
    if (byRow.has(row)) problems.push(`two files for token ${m[1]}: ${byRow.get(row)} and ${f}`);
    byRow.set(row, f);
  }
  if (unnumbered.length) say(`ignored ${unnumbered.length} PNG(s) with no number in the name`);
  const absent = [];
  for (let r = 0; r < art.rows; ++r) if (!byRow.has(r)) absent.push(r + firstToken);
  const extra = [...byRow.keys()].filter((r) => r < 0 || r >= art.rows).map((r) => r + firstToken);
  if (absent.length) problems.push(`no PNG for ${absent.length} token(s): ${absent.slice(0, 10).join(", ")}${absent.length > 10 ? ", ..." : ""}`);
  if (extra.length) problems.push(`PNGs numbered outside 1..${art.rows}: ${extra.slice(0, 10).join(", ")}`);
  say(`token PNGs       ${byRow.size} found for ${art.rows} rows (numbering starts at ${firstToken})`);

  // 5. Compare, and collect the samples for the Solidity check.
  const samples = [];
  const fullPixels = Buffer.alloc(art.rows * 1024);
  const mismatches = [];
  const unreadable = [];
  let pngFactor = null;
  let rectMin = Infinity, rectMax = 0, rectSum = 0;
  for (let r = 0; r < art.rows; ++r) {
    const f = byRow.get(r);
    if (!f) continue;
    let reduced;
    try {
      reduced = reduceTo16(decodePng(readFileSync(path.join(dir, f))), f);
    } catch (e) { unreadable.push(`${f}: ${e.message}`); continue; }
    pngFactor = pngFactor ?? reduced.factor;
    if (reduced.factor !== pngFactor) unreadable.push(`${f}: ${reduced.factor}x upscale, others are ${pngFactor}x`);
    const ours = composite(art, r);
    if (!ours.equals(reduced.pixels)) {
      let p = 0; while (p < 1024 && ours[p] === reduced.pixels[p]) ++p;
      mismatches.push({ row: r, token: r + firstToken, pixel: `(${(p >> 2) % 16}, ${(p >> 2) >> 4})` });
    }
    const rects = rectCount(reduced.pixels);
    rectMin = Math.min(rectMin, rects); rectMax = Math.max(rectMax, rects); rectSum += rects;
    reduced.pixels.copy(fullPixels, r * 1024);
    samples.push(r);
  }
  if (unreadable.length) { say(`UNREADABLE PNGs  ${unreadable.length}`); unreadable.slice(0, 20).forEach((u) => say(`  ${u}`)); problems.push(`${unreadable.length} PNG(s) could not be reduced to 16 x 16`); }
  if (mismatches.length) {
    say(`MISMATCHES       ${mismatches.length} row(s) differ between the export and the PNG`);
    mismatches.slice(0, 20).forEach((m) => say(`  token ${m.token} (row ${m.row}), first difference at pixel ${m.pixel}`));
    if (mismatches.length === samples.length && samples.length > 1) say(`  every row differs: check --first-token (is the first PNG numbered 0 or 1?)`);
    problems.push(`${mismatches.length} row(s) do not match their PNG`);
  } else if (samples.length) say(`pixel check      ${samples.length} of ${art.rows} rows match the PNGs exactly (independent compositor)`);
  if (samples.length) say(`svg rects        min ${rectMin}, max ${rectMax}, mean ${(rectSum / samples.length).toFixed(1)} per token (256 is the ceiling)`);

  // 6. The picture of every row, for the Solidity renderer check.
  if (samples.length === art.rows && !mismatches.length) {
    writeFileSync(outPath, fullPixels);
    say(`pixels file      ${outPath} (${art.rows} rows x 1024 bytes)`);
    const contractsDir = path.resolve(new URL("..", import.meta.url).pathname);
    say(`next             cd contracts && forge script script/VerifyExport.s.sol --sig "runFull(string,string)" ${path.relative(contractsDir, path.resolve(exportPath))} ${path.relative(contractsDir, path.resolve(outPath))}`);
  } else say(`pixels file      not written (fix the problems above first)`);

  const verdict = problems.length ? "FAIL" : "PASS";
  say(`result           ${verdict}`);
  problems.forEach((p) => say(`  ${p}`));
  const report = writeReport(`${path.basename(exportPath, ".json")}-art-check.txt`, `art-check ${new Date().toISOString()}\n` + lines.join("\n") + "\n");
  console.log(`summary written  ${report}`);
  process.exit(problems.length ? 1 : 0);
}

main();
