// Bun lane for the QA-status Stop gate, so gstack's /ship pre-gate (which only
// recognizes *.test.ts) can map the gate's sources to a test. The behavior is
// covered in bats; this file drives the REAL hook end to end and then runs the
// two bats files that own the gate, one file at a time (never the full suite on
// the maintainer's machine). CI's `bats hook suites` job still runs everything.
import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const REPO = resolve(import.meta.dir, "../../..");
const GATE = join(REPO, "qa/hooks/scripts/qa-status-gate.sh");
const LIB = join(REPO, "qa/hooks/scripts/qa-status-gate-lib.sh");
const LIB_TESTS =join(REPO, "qa/hooks/tests/qa-status-gate.bats");
const HOOK_TESTS = join(REPO, "qa/hooks/tests/qa-status-gate-hook.bats");

function git(cwd: string, ...args: string[]) {
  const r = Bun.spawnSync(["git", "-C", cwd, ...args]);
  if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
}

// A throwaway repo on a feature branch one commit ahead of main, so the gate
// arms exactly as it does on real shippable work.
function fixtureAhead(): string {
  const dir = mkdtempSync(join(tmpdir(), "qa-gate-"));
  git(dir, "init", "-q", "-b", "main");
  git(dir, "config", "user.email", "t@t");
  git(dir, "config", "user.name", "t");
  writeFileSync(join(dir, "seed.txt"), "seed\n");
  git(dir, "add", "seed.txt");
  git(dir, "commit", "-q", "-m", "base");
  git(dir, "checkout", "-q", "-b", "feat/x");
  writeFileSync(join(dir, "work.txt"), "work\n");
  git(dir, "add", "work.txt");
  git(dir, "commit", "-q", "-m", "work");
  return dir;
}

function runGate(message: string, cwd: string) {
  const payload = JSON.stringify({
    last_assistant_message: message,
    cwd,
    stop_hook_active: false,
  });
  const r = Bun.spawnSync(["bash", GATE], { stdin: new TextEncoder().encode(payload) });
  return { exit: r.exitCode, out: r.stdout.toString() };
}

// qa_gate_decision <message> <shippable> from the pure lib, called through bash.
function decide(message: string): string {
  const r = Bun.spawnSync(["bash", "-c", '. "$1"; qa_gate_decision "$2" 1', "_", LIB, message]);
  return r.stdout.toString().trim();
}

describe("qa_gate_decision (lib)", () => {
  test("awaiting_human outside a fence is a stated posture", () => {
    expect(decide("Done.\nQA_STATUS: awaiting_human\nDRIVER: mujtaba\nCHECK: x\nPHASE: dev")).toBe("allow");
  });

  test("awaiting_human only inside a fence is a quotation, so a done-claim still blocks", () => {
    expect(decide("All done.\n```\nQA_STATUS: awaiting_human\n```")).toBe("block");
  });
});

describe("qa-status-gate.sh (real hook)", () => {
  test("allows a stated awaiting_human posture with its companion lines", () => {
    const r = runGate(
      "Merged and deployed.\nQA_STATUS: awaiting_human\nDRIVER: mujtaba\nCHECK: run /mu:pause from the desktop app\nPHASE: prod",
      fixtureAhead(),
    );
    expect(r.exit).toBe(0);
    expect(r.out).toBe("");
  });

  test("blocks an unstated posture and lists awaiting_human + PHASE: in the reason", () => {
    const r = runGate("All done, ready to merge.", fixtureAhead());
    expect(r.exit).toBe(0);
    const reason = JSON.parse(r.out);
    expect(reason.decision).toBe("block");
    expect(reason.reason).toContain("awaiting_human");
    expect(reason.reason).toContain("PHASE:");
  });
});

describe("bats suites that own the gate (one file at a time)", () => {
  for (const file of [LIB_TESTS, HOOK_TESTS]) {
    test(file.slice(REPO.length + 1), () => {
      const r = Bun.spawnSync(["bats", file]);
      expect(r.stdout.toString()).not.toContain("not ok");
      expect(r.exitCode).toBe(0);
    }, 120_000);
  }
});
