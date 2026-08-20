#!/bin/sh
# The privacy fixture test (QPMSEC-334 / secrets-and-tenancy skill: "found
# in the open is a Bug of the highest severity"). Runs the REAL script
# end-to-end (fetch -> aggregate -> render) against fake API data in
# scripts/testdata/fixtures/ that contains a fake private repo, named
# with an obviously-fake marker per secrets-and-tenancy rule 3. Asserts:
#
#   1. the fake private repo's name never appears in the rendered block
#      (the thing this test exists to prove);
#   2. the block is still built from real per-repo data (repo count,
#      commit count, top languages) — a vacuous/no-op renderer would fail
#      this half, closing the "fixture-only satisfaction" hole qa-craft
#      rule 5 calls out;
#   3. re-running against the SAME fixtures is byte-identical (the
#      renderer is deterministic — required for the splice's
#      exit-0-with-no-diff contract).
#   4. the commit search query carries `is:public` (QPMSEC-334 fix round:
#      without it, the rendered commit count silently changes meaning by
#      executor — an ambient local token sees private commits, a scoped CI
#      app token doesn't, for the identical query string). This is a
#      direct source check, not just reliance on the fixture filename
#      matching the query — a regression here must fail loudly even if a
#      fixture happened to still be findable.
#
# Run: sh scripts/update-profile.test.sh

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FIXTURE_DIR="$SCRIPT_DIR/testdata/fixtures"
UPDATER="$SCRIPT_DIR/update-profile.sh"
LEAK_MARKER="FAKE-PRIVATE-nuclear-launch-codes-9f3e"

fail() {
  echo "update-profile.test: FAILED - $1" >&2
  exit 1
}

pass() {
  echo "update-profile.test: ok - $1"
}

# --- static check: commit search must be public-only ----------------------
# The fixture-name match below (run 1) only proves the query string is
# stable across a refactor; it can't prove the qualifier is present at all
# if a fixture for the wrong (missing-qualifier) query also happened to
# exist. Grep the actual source for the belt-and-braces guarantee.

commit_query_line=$(grep -n 'search_total_count "commits"' "$UPDATER") \
  || fail "could not find the commits search_total_count call in $UPDATER"
case "$commit_query_line" in
  *"is:public"*) pass "commit search query includes is:public" ;;
  *) fail "commit search query is missing is:public qualifier: $commit_query_line" ;;
esac

# --- run 1 --------------------------------------------------------------

block1=$(FIXTURE_DIR="$FIXTURE_DIR" SINCE_OVERRIDE=2026-07-21 TODAY_OVERRIDE=2026-08-20 \
  sh "$UPDATER" --dry-run 2>/dev/null)

[ -n "$block1" ] || fail "renderer produced empty output"

# 1. the fake private repo name must never appear in the rendered block.
case "$block1" in
  *"$LEAK_MARKER"*) fail "PRIVACY LEAK: fake private repo name '$LEAK_MARKER' appeared in rendered block: $block1" ;;
esac
pass "fake private repo name absent from rendered block"

# also guard against fragments of the marker leaking (name split/truncated)
case "$block1" in
  *"nuclear-launch"*) fail "PRIVACY LEAK: fragment of the fake private repo name appeared: $block1" ;;
esac
pass "no fragment of the fake private repo name present"

# 2. prove the block reflects real fixture data, not a vacuous stub.
# Fixtures: 3 public repos in the listing, search fixture total_count=17,
# languages summed across all 3 fixture repos (Python from the fake-private
# entry included, per the aggregate-signals-only rule: bytes may
# contribute to a sum, names may never appear).
case "$block1" in
  *"3 repositories"*) pass "repo count reflects fixture (3)" ;;
  *) fail "expected '3 repositories' in block, got: $block1" ;;
esac
case "$block1" in
  *"17 commits"*) pass "commit count reflects fixture (17)" ;;
  *) fail "expected '17 commits' in block, got: $block1" ;;
esac
case "$block1" in
  *"Python"*) pass "language aggregate reflects fixture data (Python present)" ;;
  *) fail "expected a language from fixture data in block, got: $block1" ;;
esac

# --- run 2: determinism ---------------------------------------------------

block2=$(FIXTURE_DIR="$FIXTURE_DIR" SINCE_OVERRIDE=2026-07-21 TODAY_OVERRIDE=2026-08-20 \
  sh "$UPDATER" --dry-run 2>/dev/null)

[ "$block1" = "$block2" ] || fail "renderer is not deterministic across identical inputs: '$block1' != '$block2'"
pass "renderer is deterministic (same fixtures -> byte-identical block)"

echo "update-profile.test: all checks passed"
