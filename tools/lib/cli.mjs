// Shared bits for the command-line tools.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";

/** Parse `--flag value` and `--switch` arguments; positionals in `_`. */
export function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; ++i) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const next = argv[i + 1];
      if (next === undefined || next.startsWith("--")) out[a.slice(2)] = true;
      else { out[a.slice(2)] = next; ++i; }
    } else out._.push(a);
  }
  return out;
}

/** The git top level containing `p`, or null when `p` is outside any repository. */
export function gitTopLevel(p) {
  try {
    return execFileSync("git", ["-C", path.dirname(path.resolve(p)), "rev-parse", "--show-toplevel"], { stdio: ["ignore", "pipe", "ignore"] }).toString().trim();
  } catch { return null; }
}

/** True when git ignores `p` (so it can never be committed by accident). */
export function gitIgnores(p) {
  try {
    execFileSync("git", ["-C", path.dirname(path.resolve(p)), "check-ignore", "-q", path.resolve(p)], { stdio: "ignore" });
    return true;
  } catch { return false; }
}

/**
 * The real art must never be committable. A path inside a git repository has to be ignored by
 * that repository; a path outside any repository is fine. `allowTracked` is for the committed
 * test fixture only.
 */
export function assertPrivatePath(p, what, allowTracked = false) {
  if (allowTracked) return;
  if (!existsSync(p)) throw new Error(`${what} not found: ${p}`);
  const top = gitTopLevel(p);
  if (top && !gitIgnores(p)) {
    throw new Error(`${what} ${p} is inside the repository ${top} and is not git-ignored. Put it under contracts/deploy/art/private/ or outside the repository. Refusing to continue.`);
  }
}

/** Write a report file under contracts/reports/, creating the folder. Returns the path. */
export function writeReport(name, text) {
  const dir = path.resolve(new URL("../../reports/", import.meta.url).pathname);
  mkdirSync(dir, { recursive: true });
  const p = path.join(dir, name);
  writeFileSync(p, text);
  return p;
}

export const fmt = (n) => n.toLocaleString("en-US");
