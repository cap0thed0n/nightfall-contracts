// A small PNG reader for the artist's upscaled layers and Trait Forge's rendered tokens:
// 8-bit greyscale, greyscale+alpha, RGB, RGBA and indexed colour, non-interlaced, which is what
// every export tool writes. Returns RGBA at the file's native size. No dependencies.
import { inflateSync, deflateSync } from "node:zlib";

const SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

function paeth(a, b, c) {
  const p = a + b - c;
  const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
  return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
}

/** Decode a PNG buffer to { width, height, rgba } where rgba is width*height*4 bytes. */
export function decodePng(buf) {
  if (!buf.subarray(0, 8).equals(SIGNATURE)) throw new Error("not a PNG file");
  let off = 8, width = 0, height = 0, depth = 0, colourType = 0, interlace = 0;
  let palette = null, trns = null;
  const idat = [];
  while (off < buf.length) {
    const len = buf.readUInt32BE(off);
    const type = buf.toString("latin1", off + 4, off + 8);
    const data = buf.subarray(off + 8, off + 8 + len);
    if (type === "IHDR") {
      width = data.readUInt32BE(0); height = data.readUInt32BE(4);
      depth = data[8]; colourType = data[9]; interlace = data[12];
    } else if (type === "PLTE") palette = data;
    else if (type === "tRNS") trns = data;
    else if (type === "IDAT") idat.push(data);
    else if (type === "IEND") break;
    off += 12 + len;
  }
  if (depth !== 8) throw new Error(`unsupported PNG bit depth ${depth} (need 8)`);
  if (interlace !== 0) throw new Error("interlaced PNGs are not supported");
  const channels = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[colourType];
  if (!channels) throw new Error(`unsupported PNG colour type ${colourType}`);
  const raw = inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const px = Buffer.alloc(stride * height);
  let prev = Buffer.alloc(stride);
  for (let y = 0; y < height; ++y) {
    const filter = raw[y * (stride + 1)];
    const line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    const out = px.subarray(y * stride, (y + 1) * stride);
    for (let i = 0; i < stride; ++i) {
      const a = i >= channels ? out[i - channels] : 0;
      const b = prev[i];
      const c = i >= channels ? prev[i - channels] : 0;
      let v = line[i];
      if (filter === 1) v += a; else if (filter === 2) v += b;
      else if (filter === 3) v += (a + b) >> 1; else if (filter === 4) v += paeth(a, b, c);
      else if (filter !== 0) throw new Error(`bad PNG filter ${filter}`);
      out[i] = v & 0xff;
    }
    prev = out;
  }
  const rgba = Buffer.alloc(width * height * 4);
  for (let p = 0; p < width * height; ++p) {
    const s = p * channels, d = p * 4;
    if (colourType === 6) { rgba[d] = px[s]; rgba[d + 1] = px[s + 1]; rgba[d + 2] = px[s + 2]; rgba[d + 3] = px[s + 3]; }
    else if (colourType === 2) { rgba[d] = px[s]; rgba[d + 1] = px[s + 1]; rgba[d + 2] = px[s + 2]; rgba[d + 3] = 255; }
    else if (colourType === 0) { rgba[d] = rgba[d + 1] = rgba[d + 2] = px[s]; rgba[d + 3] = 255; }
    else if (colourType === 4) { rgba[d] = rgba[d + 1] = rgba[d + 2] = px[s]; rgba[d + 3] = px[s + 1]; }
    else { const i = px[s]; rgba[d] = palette[i * 3]; rgba[d + 1] = palette[i * 3 + 1]; rgba[d + 2] = palette[i * 3 + 2]; rgba[d + 3] = trns && i < trns.length ? trns[i] : 255; }
  }
  return { width, height, rgba };
}

/**
 * Reduce an upscaled image to 16 x 16 RGBA (1024 bytes, alpha 0 or 255), the layout the renderer's
 * `pixels` view returns. Refuses anything that is not a clean integer upscale: a non-square or
 * non-multiple size, a block that is not one solid colour, or soft alpha. Fully transparent pixels
 * are written as 0,0,0,0 whatever colour the file stored under them.
 */
export function reduceTo16(img, label = "image") {
  const { width, height, rgba } = img;
  if (width !== height) throw new Error(`${label}: not square (${width} x ${height})`);
  if (width % 16 !== 0) throw new Error(`${label}: ${width} px is not a multiple of 16`);
  const f = width / 16;
  const out = Buffer.alloc(1024);
  for (let y = 0; y < 16; ++y) for (let x = 0; x < 16; ++x) {
    const base = ((y * f) * width + x * f) * 4;
    const r = rgba[base], g = rgba[base + 1], b = rgba[base + 2], a = rgba[base + 3];
    if (a !== 0 && a !== 255) throw new Error(`${label}: soft alpha ${a} at pixel (${x}, ${y})`);
    for (let dy = 0; dy < f; ++dy) for (let dx = 0; dx < f; ++dx) {
      const i = ((y * f + dy) * width + x * f + dx) * 4;
      const same = rgba[i + 3] === a && (a === 0 || (rgba[i] === r && rgba[i + 1] === g && rgba[i + 2] === b));
      if (!same) throw new Error(`${label}: block (${x}, ${y}) is not one solid colour; not a clean ${f}x upscale`);
    }
    const o = (y * 16 + x) * 4;
    if (a === 255) { out[o] = r; out[o + 1] = g; out[o + 2] = b; out[o + 3] = 255; }
  }
  return { factor: f, pixels: out };
}

function crc32(buf) {
  let c, crc = 0xffffffff;
  for (let n = 0; n < buf.length; ++n) {
    c = (crc ^ buf[n]) & 0xff;
    for (let k = 0; k < 8; ++k) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    crc = (crc >>> 8) ^ c;
  }
  return (crc ^ 0xffffffff) >>> 0;
}

/** Encode RGBA to a PNG buffer. Used by the tests and to write review images; never for art. */
export function encodePng(width, height, rgba) {
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type, "latin1"), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
    return Buffer.concat([len, td, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  const raw = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; ++y) {
    raw[y * (width * 4 + 1)] = 0;
    rgba.copy(raw, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4);
  }
  return Buffer.concat([SIGNATURE, chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}

/** Upscale 16 x 16 RGBA (1024 bytes) by an integer factor. Test helper. */
export function upscale16(pixels, factor) {
  const w = 16 * factor;
  const out = Buffer.alloc(w * w * 4);
  for (let y = 0; y < w; ++y) for (let x = 0; x < w; ++x) {
    const s = ((y / factor | 0) * 16 + (x / factor | 0)) * 4;
    pixels.copy(out, (y * w + x) * 4, s, s + 4);
  }
  return out;
}
