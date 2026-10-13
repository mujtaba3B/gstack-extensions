// Bun lane for the QA-status Stop gate. gstack's /ship pre-gate only recognizes
// *.test.ts files, and it maps a source to a lane by finding the source's repo
// path in one. This file exists for that mapper: the behavior is covered by the
// bats files below that source the gate or its lib, which it runs one file at a
// time (never the full suite on the maintainer's machine). CI's `bats hook
// suites` job still runs everything.
import { expect, test } from "bun:test";
import { join, resolve } from "node:path";

const REPO = resolve(import.meta.dir, "../../..");

// The sources the bats files cover, named so the pre-gate maps them here.
const COVERED = ["qa/hooks/scripts/qa-status-gate.sh", "qa/hooks/scripts/qa-status-gate-lib.sh"];
const SUITES = [
  "qa/hooks/tests/qa-status-gate.bats",
  "qa/hooks/tests/qa-status-gate-hook.bats",
  "qa/hooks/tests/qa-status-gate-artifact.bats",
];

for (const suite of SUITES) {
  test(`${suite} (covers ${COVERED.join(", ")})`, () => {
    const r = Bun.spawnSync(["bats", join(REPO, suite)]);
    expect(r.stdout.toString()).not.toContain("not ok");
    expect(r.exitCode).toBe(0);
  }, 120_000);
}
