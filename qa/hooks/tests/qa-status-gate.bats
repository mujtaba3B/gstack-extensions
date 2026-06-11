#!/usr/bin/env bats
# Unit tests for the pure decision function behind the QA-status Stop gate.

setup() {
  load_lib="$BATS_TEST_DIRNAME/../scripts/qa-status-gate-lib.sh"
  # shellcheck source=/dev/null
  . "$load_lib"
}

@test "blocks: completion claim + shippable + no QA_STATUS" {
  run qa_gate_decision "All done, the PR is up and CI is green." 1
  [ "$output" = "block" ]
}

@test "blocks: 'ready to merge' on shippable work" {
  run qa_gate_decision "This is ready to merge." 1
  [ "$output" = "block" ]
}

@test "allows: QA_STATUS already stated (verified)" {
  run qa_gate_decision "Done. QA_STATUS: verified EVIDENCE: ran scenario 1, 302 to /preview/" 1
  [ "$output" = "allow" ]
}

@test "allows: QA_STATUS skip_requested counts as stated posture" {
  run qa_gate_decision "Done. QA_STATUS: skip_requested REASON: config-only, nothing to exercise." 1
  [ "$output" = "allow" ]
}

@test "allows: QA_STATUS no_tracked_change (docs/memory-only turn, tree dirtied by a sibling's tracked edit)" {
  run qa_gate_decision "Closed out. QA_STATUS: no_tracked_change (only LOG.md/memory; the dirty where-things-run.json is another pane's)." 1
  [ "$output" = "allow" ]
}

@test "allows: QA_STATUS dev_verified (phase-aware Development QA)" {
  run qa_gate_decision "Done. QA_STATUS: dev_verified EVIDENCE: ran the dev QA plan on the preview, all scenarios green." 1
  [ "$output" = "allow" ]
}

@test "allows: QA_STATUS prod_verified (phase-aware Production QA, post-deploy)" {
  run qa_gate_decision "Deployed. QA_STATUS: prod_verified EVIDENCE: smoke + canary green in prod." 1
  [ "$output" = "allow" ]
}

@test "allows: deploy_branch_for_manual_qa handed to human (terminal turn-ender)" {
  run qa_gate_decision "$(printf 'Branch is up.\nQA_STATUS: deploy_branch_for_manual_qa\nDRIVER: human\nDEPLOYED: mutwos-mac-mini @ fix/cards, run: email-hero feedback')" 1
  [ "$output" = "allow" ]
}

@test "allows: deploy_branch_for_manual_qa driven by agent" {
  run qa_gate_decision "$(printf 'Done.\nQA_STATUS: deploy_branch_for_manual_qa\nDRIVER: agent\nDEPLOYED: mutwos-mac-mini @ fix/cards, run: email-hero feedback\nEVIDENCE: cards render with subject + sender')" 1
  [ "$output" = "allow" ]
}

@test "allows: completion claim but no shippable work (pure conversation)" {
  run qa_gate_decision "Done explaining. Here is how it works." 0
  [ "$output" = "allow" ]
}

@test "allows: shippable work but no completion claim (mid-build)" {
  run qa_gate_decision "I have written the resolver and am about to add tests." 1
  [ "$output" = "allow" ]
}

@test "allows: empty message" {
  run qa_gate_decision "" 1
  [ "$output" = "allow" ]
}

@test "allows: negated completion 'not done yet' (false-positive guard)" {
  run qa_gate_decision "I'm not done yet, still wiring up the tests." 1
  [ "$output" = "allow" ]
}

@test "allows: negated 'isn't ready to merge'" {
  run qa_gate_decision "This isn't ready to merge, one edge case left." 1
  [ "$output" = "allow" ]
}

@test "allows: trigger word only inside a fenced code block" {
  run qa_gate_decision "$(printf 'Here is the rule:\n```\nblocks when you say done or shipped\n```\nStill working on it.')" 1
  [ "$output" = "allow" ]
}

@test "blocks: real completion claim outside any code fence" {
  run qa_gate_decision "$(printf 'Implemented and pushed.\n```\nsome code\n```\nThe PR is up and ready to merge.')" 1
  [ "$output" = "block" ]
}

@test "allows: 'done' substring inside another word must not over-trigger" {
  run qa_gate_decision "I abandoned that approach and refactored instead." 1
  [ "$output" = "allow" ]
}
