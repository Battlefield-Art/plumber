#!/usr/bin/env bash
# Unit tests for release-propagate-pins.sh.
# Run: bash scripts/release-propagate-pins.test.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/release-propagate-pins.sh"
fails=0

assert_contains() { # file needle label
  if grep -qF -- "$2" "$1"; then echo "ok: $3"; else echo "FAIL: $3 (missing: $2)"; fails=$((fails+1)); fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

OLD_SHA="1111111111111111111111111111111111111111"
NEW_SHA="2222222222222222222222222222222222222222"
OLD_HEX="$(printf 'a%.0s' {1..64})"
NEW_HEX="$(printf 'b%.0s' {1..64})"

mkdir -p "$tmp/target/docs"
cat > "$tmp/target/docs/sample.yml" <<EOF
- uses: getplumber/plumber@${OLD_SHA} # pinned plumber version: v0.4.13
image: "getplumber/plumber@sha256:${OLD_HEX}" # pinned plumber version: v0.4.13
- component: gitlab.com/getplumber/plumber/plumber@0.4.13 # pinned plumber version
- uses: getplumber/plumber@${OLD_SHA} # v0.4.13 unmarked, must stay
EOF
cat > "$tmp/target/docs/above.ts" <<EOF
// Pinned plumber version
const version = "v0.4.13";
const frozen = "v0.3.11";
EOF

bash "$script" 0.9.9 "$NEW_SHA" "sha256:${NEW_HEX}" "$tmp/target"

s="$tmp/target/docs/sample.yml"
a="$tmp/target/docs/above.ts"
assert_contains "$s" "getplumber/plumber@${NEW_SHA} # pinned plumber version: v0.9.9" "sha pin + label rewritten"
assert_contains "$s" "sha256:${NEW_HEX}\" # pinned plumber version: v0.9.9" "digest + label rewritten"
assert_contains "$s" "plumber/plumber@0.9.9 # pinned plumber version" "bare version stays bare"
assert_contains "$s" "getplumber/plumber@${OLD_SHA} # v0.4.13 unmarked, must stay" "unmarked line untouched"
assert_contains "$a" 'const version = "v0.9.9";' "marker-above rewrites next line"
assert_contains "$a" 'const frozen = "v0.3.11";' "line after the target untouched"

# Idempotency: second run changes nothing.
snap1="$(cat "$s" "$a")"
bash "$script" 0.9.9 "$NEW_SHA" "sha256:${NEW_HEX}" "$tmp/target" > /dev/null
snap2="$(cat "$s" "$a")"
if [ "$snap1" = "$snap2" ]; then echo "ok: idempotent"; else echo "FAIL: idempotent"; fails=$((fails+1)); fi

# No markers: distinct message, exit 0, file untouched.
mkdir -p "$tmp/none"; echo 'version v0.4.13' > "$tmp/none/x.md"
out="$(bash "$script" 0.9.9 "$NEW_SHA" "sha256:${NEW_HEX}" "$tmp/none")"
case "$out" in *"no 'pinned plumber version' markers"*) echo "ok: no-marker message";; *) echo "FAIL: no-marker message"; fails=$((fails+1));; esac
assert_contains "$tmp/none/x.md" "v0.4.13" "unmarked file untouched"

# Bad args rejected.
if bash "$script" nonsense "$NEW_SHA" "sha256:${NEW_HEX}" "$tmp/none" 2>/dev/null; then
  echo "FAIL: bad version accepted"; fails=$((fails+1))
else echo "ok: bad version rejected"; fi

# Dangling standalone marker at EOF must be fatal (exit 3), not silent.
mkdir -p "$tmp/dangle1"
printf '# download the pinned plumber version below\n' > "$tmp/dangle1/x.ts"
set +e
bash "$script" 0.9.9 "$NEW_SHA" "sha256:${NEW_HEX}" "$tmp/dangle1" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 3 ]; then echo "ok: EOF dangling marker fatal (exit 3)"; else echo "FAIL: EOF dangling marker fatal (rc=$rc)"; fails=$((fails+1)); fi

# Two standalone markers in a row: the first dangles (fatal), the second
# still rewrites its target line.
mkdir -p "$tmp/dangle2"
printf '// pinned plumber version\n// pinned plumber version\nconst v = "v0.4.13";\n' > "$tmp/dangle2/y.ts"
set +e
bash "$script" 0.9.9 "$NEW_SHA" "sha256:${NEW_HEX}" "$tmp/dangle2" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 3 ]; then echo "ok: double standalone marker fatal (exit 3)"; else echo "FAIL: double standalone marker fatal (rc=$rc)"; fails=$((fails+1)); fi
assert_contains "$tmp/dangle2/y.ts" 'const v = "v0.9.9";' "second marker still rewrites its target"

# GitLab component SHA-pinning: two-pass deferral.
# A component line already pinned by SHA must be left COMPLETELY untouched
# (neither SHA nor version label) when no component-sha is supplied, so a
# tagged commit never shows a mismatched SHA/version pair. A sibling
# GitHub Action SHA-pin line must be rewritten normally in the same pass --
# this is the regression test for the false-positive found in review:
# "getplumber" itself ends in "plumber", so a naive "plumber/plumber@"
# match also fires inside "getplumber/plumber@<sha>".
COMP_OLD_SHA="3333333333333333333333333333333333333333"
COMP_NEW_SHA="4444444444444444444444444444444444444444"
mkdir -p "$tmp/component"
cat > "$tmp/component/README.md" <<EOF
- uses: getplumber/plumber@${OLD_SHA} # pinned plumber version: v0.4.13
- component: gitlab.com/getplumber/plumber/plumber@${COMP_OLD_SHA} # pinned plumber version: v0.4.13
EOF

# Pass 1: no component-sha (positional arg omitted). The Action SHA line
# must still update; the component SHA line must stay byte-for-byte,
# including its stale version label.
bash "$script" 0.9.9 "$NEW_SHA" "sha256:${NEW_HEX}" "$tmp/component"
c="$tmp/component/README.md"
assert_contains "$c" "getplumber/plumber@${NEW_SHA} # pinned plumber version: v0.9.9" "sibling Action SHA line rewritten during deferral pass"
assert_contains "$c" "getplumber/plumber/plumber@${COMP_OLD_SHA} # pinned plumber version: v0.4.13" "component SHA+label deferred as a matched pair (pass 1)"

# Pass 2: same tree, now with component-sha as the 5th arg. Only the
# deferred line should change; the already-updated Action line must be
# idempotent (rule 1 doesn't touch a getplumber/plumber/plumber@ line, and
# vice versa).
bash "$script" 0.9.9 "$NEW_SHA" "sha256:${NEW_HEX}" "$tmp/component" "$COMP_NEW_SHA"
assert_contains "$c" "getplumber/plumber/plumber@${COMP_NEW_SHA} # pinned plumber version: v0.9.9" "component SHA+label rewritten together once sha is known (pass 2)"
assert_contains "$c" "getplumber/plumber@${NEW_SHA} # pinned plumber version: v0.9.9" "Action SHA line untouched by pass 2"

# Bad component-sha rejected (5th positional arg, when non-empty, must be
# 40 hex chars like the other sha args).
if bash "$script" 0.9.9 "$NEW_SHA" "sha256:${NEW_HEX}" "$tmp/component" "not-a-sha" 2>/dev/null; then
  echo "FAIL: bad component sha accepted"; fails=$((fails+1))
else echo "ok: bad component sha rejected"; fi

# Self-hosted-mirror namespace: the component-pin rule must match ANY
# namespace ending in /plumber/plumber@<sha> (a faithful GitLab import
# preserves commit SHAs regardless of host), not just getplumber's own.
# This is the regression test for the second false-positive risk: loosening
# the match to a bare "plumber/plumber@" fragment (dropping the
# "getplumber" requirement) must NOT reopen the original collision with
# rule 1's getplumber/plumber@<sha> lines, which is why the match requires
# a literal "/" immediately before "plumber/plumber@".
mkdir -p "$tmp/selfhosted"
cat > "$tmp/selfhosted/README.md" <<EOF
- uses: getplumber/plumber@${OLD_SHA} # pinned plumber version: v0.4.13
- component: gitlab.example.com/infrastructure/plumber/plumber@${COMP_OLD_SHA} # pinned plumber version: v0.4.13
EOF
sh="$tmp/selfhosted/README.md"
bash "$script" 0.9.9 "$NEW_SHA" "sha256:${NEW_HEX}" "$tmp/selfhosted"
assert_contains "$sh" "getplumber/plumber@${NEW_SHA} # pinned plumber version: v0.9.9" "sibling Action SHA line rewritten (self-hosted namespace pass 1)"
assert_contains "$sh" "gitlab.example.com/infrastructure/plumber/plumber@${COMP_OLD_SHA} # pinned plumber version: v0.4.13" "self-hosted namespace component line deferred as a matched pair (pass 1)"
bash "$script" 0.9.9 "$NEW_SHA" "sha256:${NEW_HEX}" "$tmp/selfhosted" "$COMP_NEW_SHA"
assert_contains "$sh" "gitlab.example.com/infrastructure/plumber/plumber@${COMP_NEW_SHA} # pinned plumber version: v0.9.9" "self-hosted namespace preserved, sha+label rewritten together (pass 2)"

if [ "$fails" -gt 0 ]; then echo "${fails} failure(s)"; exit 1; fi
echo "all release-propagate-pins tests passed"
