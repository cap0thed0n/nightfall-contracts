// keccak256 with no dependencies, so the tools run on a plain Node install. BigInt lanes; fast
// enough for the few kilobytes an export table holds.
const RC = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];
const ROT = [0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14];
const PI = [0, 10, 20, 5, 15, 16, 1, 11, 21, 6, 7, 17, 2, 12, 22, 23, 8, 18, 3, 13, 14, 24, 9, 19, 4];
const M64 = (1n << 64n) - 1n;
const rotl = (x, n) => n === 0 ? x : ((x << BigInt(n)) | (x >> BigInt(64 - n))) & M64;

function keccakF(s) {
  for (let round = 0; round < 24; ++round) {
    const c = [0n, 0n, 0n, 0n, 0n];
    for (let x = 0; x < 5; ++x) c[x] = s[x] ^ s[x + 5] ^ s[x + 10] ^ s[x + 15] ^ s[x + 20];
    for (let x = 0; x < 5; ++x) {
      const d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1);
      for (let y = 0; y < 25; y += 5) s[x + y] ^= d;
    }
    const b = new Array(25);
    for (let i = 0; i < 25; ++i) b[PI[i]] = rotl(s[i], ROT[i]);
    for (let y = 0; y < 25; y += 5) {
      for (let x = 0; x < 5; ++x) s[y + x] = b[y + x] ^ ((~b[y + (x + 1) % 5] & M64) & b[y + (x + 2) % 5]);
    }
    s[0] ^= RC[round];
  }
}

/** keccak256 of a Buffer or Uint8Array, returned as a Buffer of 32 bytes. */
export function keccak256(input) {
  const data = Buffer.from(input);
  const rate = 136;
  const padded = Buffer.alloc(Math.floor(data.length / rate) * rate + rate);
  data.copy(padded);
  padded[data.length] ^= 0x01;
  padded[padded.length - 1] ^= 0x80;
  const s = new Array(25).fill(0n);
  for (let off = 0; off < padded.length; off += rate) {
    for (let i = 0; i < rate / 8; ++i) s[i] ^= padded.readBigUInt64LE(off + i * 8);
    keccakF(s);
  }
  const out = Buffer.alloc(32);
  for (let i = 0; i < 4; ++i) out.writeBigUInt64LE(s[i], i * 8);
  return out;
}

export const keccak256Hex = (input) => "0x" + keccak256(input).toString("hex");
