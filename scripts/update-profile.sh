#!/bin/sh
# Renders the DYNAMIC block in profile/README.md from AGGREGATE GitHub API
# signals only (repo count, summed language bytes, commit count trailing
# 30 days) and splices it between the markers. Everything outside the
# markers is never touched.
#
# THIS REPO IS PUBLIC. Hard privacy rule (owner order, QPMSEC-334): no
# repo name, description, or per-repo detail may ever reach the rendered
# block. The architecture enforces this structurally, not by convention:
#
#   fetch_repo_names   -> repo names exist ONLY inside this function's
#                          local scope, used solely to build per-repo URLs.
#   aggregate_languages -> receives repo names as loop input but its
#                          accumulator is keyed by LANGUAGE, never by repo;
#                          a repo name cannot flow into its output by
#                          construction (there is no field to put it in).
#   build_aggregate     -> the ONLY function whose output is handed to
#                          render_block. Its schema is fixed:
#                          {repo_count, top_languages, commits_30d, date}.
#                          No key in that schema can hold a repo name.
#   render_block        -> pure function of build_aggregate's output.
#                          Never sees raw API responses.
#
# scripts/update-profile.test.sh proves this with fake API data containing
# a fake private repo name and asserts it never reaches the rendered block.
#
# Usage:
#   scripts/update-profile.sh                # fetch real data, splice, write
#   scripts/update-profile.sh --dry-run       # fetch real data, print block, don't write
#   FIXTURE_DIR=t/fixtures scripts/update-profile.sh --dry-run   # offline, for tests
#
# Env:
#   GITHUB_TOKEN   required unless FIXTURE_DIR is set
#   OWNER          default: QPMatrix
#   README_PATH    default: profile/README.md (relative to repo root)
#   TOP_N_LANGS    default: 4

set -eu

OWNER="${OWNER:-QPMatrix}"
TOP_N_LANGS="${TOP_N_LANGS:-4}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
README_PATH="${README_PATH:-$REPO_ROOT/profile/README.md}"
MARK_START='<!-- DYNAMIC:START -->'
MARK_END='<!-- DYNAMIC:END -->'

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
  esac
done

# ---- fetch layer -----------------------------------------------------

gh_api() {
  # $1 = API path (no leading slash), no host
  path="$1"
  if [ -n "${FIXTURE_DIR:-}" ]; then
    key=$(printf '%s' "$path" | tr -c 'A-Za-z0-9._-' '_')
    file="$FIXTURE_DIR/$key.json"
    if [ ! -f "$file" ]; then
      echo "update-profile: missing fixture for '$path' -> $file" >&2
      return 1
    fi
    cat "$file"
  else
    : "${GITHUB_TOKEN:?GITHUB_TOKEN required (or set FIXTURE_DIR for offline runs)}"
    curl -fsS \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/$path"
  fi
}

since_30d() {
  # SINCE_OVERRIDE/TODAY_OVERRIDE exist so tests are deterministic — never
  # set them in production use.
  if [ -n "${SINCE_OVERRIDE:-}" ]; then
    printf '%s\n' "$SINCE_OVERRIDE"
  elif date -v-30d +%Y-%m-%d >/dev/null 2>&1; then
    date -u -v-30d +%Y-%m-%d
  else
    date -u -d '30 days ago' +%Y-%m-%d
  fi
}

owner_type() {
  gh_api "users/$OWNER" | jq -r '.type'
}

# repo names live ONLY in this function's local scope (and the caller's
# loop variable). Nothing here is ever echoed into an aggregate.
fetch_repo_names() {
  otype="$1"
  if [ "$otype" = "Organization" ]; then
    gh_api "orgs/$OWNER/repos?type=public&per_page=100" | jq -r '.[].name'
  else
    gh_api "users/$OWNER/repos?type=public&per_page=100" | jq -r '.[].name'
  fi
}

# Accumulator keyed by LANGUAGE only — there is no field a repo name could
# occupy in this output, by construction.
aggregate_languages() {
  # reads repo names on stdin, one per line
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  echo '{}' > "$tmp"
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    langs=$(gh_api "repos/$OWNER/$repo/languages")
    merged=$(jq -n --argjson acc "$(cat "$tmp")" --argjson add "$langs" \
      '$acc as $a | $add | to_entries | reduce .[] as $e ($a; .[$e.key] = (($a[$e.key] // 0) + $e.value))')
    echo "$merged" > "$tmp"
  done
  cat "$tmp"
}

search_total_count() {
  # $1 = search endpoint (issues|commits), $2 = query
  endpoint="$1"
  query="$2"
  encoded=$(printf '%s' "$query" | jq -sRr @uri)
  gh_api "search/$endpoint?q=$encoded" | jq -r '.total_count // 0'
}

# The ONLY function whose output reaches render_block. Fixed schema.
build_aggregate() {
  otype=$(owner_type)
  qualifier="user"
  [ "$otype" = "Organization" ] && qualifier="org"

  repo_names=$(fetch_repo_names "$otype")
  repo_count=$(printf '%s\n' "$repo_names" | grep -c . || true)

  lang_json=$(printf '%s\n' "$repo_names" | aggregate_languages)
  top_langs=$(printf '%s' "$lang_json" | jq -r --argjson n "$TOP_N_LANGS" \
    'to_entries | sort_by(-.value) | .[0:$n] | map(.key)')

  since=$(since_30d)
  commits_30d=$(search_total_count "commits" "$qualifier:$OWNER committer-date:>$since")
  today="${TODAY_OVERRIDE:-$(date -u +%Y-%m-%d)}"

  jq -n \
    --argjson repo_count "$repo_count" \
    --argjson top_langs "$top_langs" \
    --argjson commits_30d "$commits_30d" \
    --arg today "$today" \
    '{repo_count: $repo_count, top_languages: $top_langs, commits_30d: $commits_30d, date: $today}'
}

# ---- render layer (pure) ----------------------------------------------

render_block() {
  # reads aggregate JSON on stdin -> markdown line on stdout
  jq -r '
    (.top_languages | join("/")) as $langs |
    "\(.repo_count) repositories · \(.commits_30d) commits this month" +
    (if ($langs | length) > 0 then " · powered by \($langs)" else "" end) +
    " · updated \(.date)"
  '
}

# ---- splice layer -------------------------------------------------------

splice() {
  block="$1"
  file="$README_PATH"
  if ! grep -qF "$MARK_START" "$file" || ! grep -qF "$MARK_END" "$file"; then
    echo "update-profile: markers not found in $file" >&2
    return 1
  fi
  new_line="${MARK_START}${block}${MARK_END}"
  tmp=$(mktemp)
  awk -v start="$MARK_START" -v end="$MARK_END" -v newline="$new_line" '
    index($0, start) {
      pre = substr($0, 1, index($0, start) - 1)
      rest = substr($0, index($0, start))
      post = substr(rest, index(rest, end) + length(end))
      print pre newline post
      next
    }
    { print }
  ' "$file" > "$tmp"
  if cmp -s "$tmp" "$file"; then
    rm -f "$tmp"
    echo "update-profile: no change"
    return 0
  fi
  mv "$tmp" "$file"
  echo "update-profile: profile/README.md updated"
}

main() {
  aggregate=$(build_aggregate)
  block=$(printf '%s' "$aggregate" | render_block)
  echo "update-profile: rendered block:" >&2
  echo "  $block" >&2
  if [ "$DRY_RUN" = 1 ]; then
    printf '%s\n' "$block"
    return 0
  fi
  splice "$block"
}

main "$@"
