#!/usr/bin/env bats
# gate-policy-lib.sh ships in BOTH the eng and qa plugins, because a qa gate must
# not depend on an eng-only lib at runtime. Duplication is only safe while the two
# copies are byte-identical, so that is asserted rather than assumed.

@test "the eng and qa copies of gate-policy-lib.sh are byte-identical" {
  eng="${BATS_TEST_DIRNAME}/../scripts/gate-policy-lib.sh"
  qa="${BATS_TEST_DIRNAME}/../../../qa/hooks/scripts/gate-policy-lib.sh"
  [ -f "$eng" ]
  [ -f "$qa" ]
  run cmp -s "$eng" "$qa"
  [ "$status" -eq 0 ]
}
