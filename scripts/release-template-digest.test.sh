#!/usr/bin/env bash
# Unit tests for release-template-digest.sh.
# Run: bash scripts/release-template-digest.test.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/release-template-digest.sh"
fails=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

HEX="$(printf 'c%.0s' {1..64})"
cat > "$tmp/plumber.yml" <<EOF
    image:
      default: "getplumber/plumber@sha256:${HEX}" #v0.4.16
EOF

got="$(bash "$script" 0.4.16 "$tmp/plumber.yml")"
if [ "$got" = "sha256:${HEX}" ]; then echo "ok: digest extracted"; else echo "FAIL: digest extracted (got: $got)"; fails=$((fails+1)); fi

if bash "$script" 0.4.17 "$tmp/plumber.yml" 2>/dev/null; then
  echo "FAIL: version mismatch accepted"; fails=$((fails+1))
else echo "ok: version mismatch rejected"; fi

# No digest line: must fail WITH a diagnostic (not a silent set -e death).
printf 'image: "getplumber/plumber:latest"\n' > "$tmp/nodigest.yml"
set +e
out="$(bash "$script" 0.4.16 "$tmp/nodigest.yml" 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'no digest-pinned image line'; then
  echo "ok: no-digest-line rejected with message"
else
  echo "FAIL: no-digest-line rejected with message (rc=$rc out=$out)"; fails=$((fails+1))
fi

# Missing template file: fail with a diagnostic.
set +e
out="$(bash "$script" 0.4.16 "$tmp/does-not-exist.yml" 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'template file not found'; then
  echo "ok: missing template rejected with message"
else
  echo "FAIL: missing template rejected with message (rc=$rc out=$out)"; fails=$((fails+1))
fi

if [ "$fails" -gt 0 ]; then echo "${fails} failure(s)"; exit 1; fi
echo "all release-template-digest tests passed"
