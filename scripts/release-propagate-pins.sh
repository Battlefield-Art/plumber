#!/usr/bin/env bash
# Rewrite marked lines in a target checkout to a given release.
# A marker is any line containing the phrase "pinned plumber version"
# (case-insensitive, any comment syntax, may sit inside a longer
# sentence). If the marker line itself
# contains a rewritable reference, that line is the target; otherwise the
# line directly below it is. Standalone marker lines must
# not contain a version-looking token.
#
# On a target line, rewrites in order:
#   1. getplumber/plumber@<40-hex>   -> getplumber/plumber@<commit-sha>
#   2. <namespace>/plumber/plumber@<40-hex> -> <namespace>/plumber/plumber@<component-sha>
#      (GitLab component SHA pin, e.g. gitlab.com/getplumber/plumber/plumber@<sha>
#      or a self-hosted mirror's own namespace, e.g.
#      gitlab.example.com/infrastructure/plumber/plumber@<sha> -- a faithful
#      GitLab import/mirror preserves commit SHAs byte-for-byte, so the same
#      sha is valid regardless of which namespace hosts it. Matched by
#      requiring a literal "/" immediately before "plumber/plumber@", not a
#      bare "plumber/plumber@" fragment: "getplumber" itself ends in
#      "plumber" with no preceding "/", so a bare fragment would also
#      (wrongly) match inside rule 1's 2-segment getplumber/plumber@<sha>
#      lines, which have no "/" before their own "plumber". Only rewritten
#      when <component-sha> is given -- see "Component SHA deferral"
#      below.)
#   3. getplumber/plumber@sha256:<hex>      -> getplumber/plumber@sha256:<digest>
#   4. every X.Y.Z numeric token            -> <version>  (v prefix preserved)
# Only marked lines are ever touched.
#
# A standalone marker with no line below it, or directly followed by
# another standalone marker, has no target: that is a dangling marker and
# the script exits 3 after processing every file (a marked pin must never
# go silently stale).
#
# Component SHA deferral: a line already pinned in the
# <namespace>/plumber/plumber@<40-hex> form is special-cased -- if
# <component-sha> is omitted, such a line is left completely untouched,
# neither its SHA nor its version label changing, so it stays internally
# consistent (both fields describe the same, merely one-release-stale, real
# prior release) instead of drifting into a mismatched SHA/version pair.
# This exists because a commit's SHA is a hash of its own tree, so it can
# never embed its own SHA: a caller that needs a line to reference a commit
# it's about to create runs this script twice on the same checkout -- once
# before that commit exists (component-sha omitted, so these lines defer),
# then again once its SHA is known (component-sha supplied, so the deferred
# lines catch up). Everything else on the line is unaffected by this
# deferral.
#
# Usage: release-propagate-pins.sh <version> <commit-sha> <digest> <target-dir> [component-sha]
#   <version>        e.g. 0.4.17 (no leading v)
#   <commit-sha>     40-hex commit the release tag points at
#   <digest>         image digest, with or without the sha256: prefix
#   <component-sha>  optional; 40-hex commit of the GitLab component's own
#                    sync commit, once known
set -euo pipefail
ver="${1:?version required}"
sha="${2:?commit sha required}"
digest="${3:?image digest required}"
dir="${4:?target dir required}"
compsha="${5:-}"
hex="${digest#sha256:}"

[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad version: $ver" >&2; exit 2; }
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "bad commit sha: $sha" >&2; exit 2; }
[[ "$hex" =~ ^[0-9a-f]{64}$ ]] || { echo "bad digest: $digest" >&2; exit 2; }
if [[ -n "$compsha" ]]; then
  [[ "$compsha" =~ ^[0-9a-f]{40}$ ]] || { echo "bad component sha: $compsha" >&2; exit 2; }
fi

files="$(grep -rIli --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=dist 'pinned plumber version' "$dir" || true)"
if [[ -z "$files" ]]; then
  echo "release-propagate-pins: no 'pinned plumber version' markers found under $dir"
  exit 0
fi

total=0
dangling=0
while IFS= read -r f; do
  before="$(mktemp)"
  cp "$f" "$before"
  if ! PP_VER="$ver" PP_SHA="$sha" PP_HEX="$hex" PP_COMPSHA="$compsha" perl -i -pe '
    BEGIN { $v=$ENV{PP_VER}; $s=$ENV{PP_SHA}; $h=$ENV{PP_HEX}; $c=$ENV{PP_COMPSHA}; $pending=0 }
    my $t = 0;
    if (/pinned plumber version/i) {
      if (/getplumber\/plumber\@[0-9a-f]{40}/ or /\/plumber\/plumber\@[0-9a-f]{40}/ or /\@sha256:[0-9a-f]+/ or /\d+\.\d+\.\d+/) {
        $t = 1; $pending = 0;
      } else {
        if ($pending) { warn "dangling '\''pinned plumber version'\'' marker: $ARGV line " . ($. - 1) . " has no target line\n"; $bad = 1 }
        $pending = 1;
      }
    } elsif ($pending) {
      $t = 1; $pending = 0;
    }
    if ($t) {
      my $is_component_pin = /\/plumber\/plumber\@[0-9a-f]{40}/;
      if ($is_component_pin && !length($c)) {
        # Deferred: no component sha yet this pass. Leave the whole line
        # untouched so its sha and version label stay a matched pair.
      } else {
        if ($is_component_pin) {
          s/\/plumber\/plumber\@[0-9a-f]{40}/\/plumber\/plumber\@$c/g;
        } else {
          s/getplumber\/plumber\@[0-9a-f]{40}/getplumber\/plumber\@$s/g;
        }
        s/getplumber\/plumber\@sha256:[0-9a-f]+/getplumber\/plumber\@sha256:$h/g;
        s/\d+\.\d+\.\d+/$v/g;
      }
    }
    END {
      if ($pending) { warn "dangling '\''pinned plumber version'\'' marker at end of $ARGV\n"; $bad = 1 }
      exit 1 if $bad;
    }
  ' "$f"; then
    dangling=1
  fi
  if ! cmp -s "$before" "$f"; then
    n="$(diff "$before" "$f" | grep -c '^<' || true)"
    echo "± $f"
    diff "$before" "$f" || true
    total=$((total + n))
  fi
  rm -f "$before"
done <<< "$files"
echo "release-propagate-pins: rewrote ${total} line(s)"
if [[ "$dangling" -ne 0 ]]; then
  echo "release-propagate-pins: dangling 'pinned plumber version' marker(s) found; fix the markers (see warnings above)" >&2
  exit 3
fi
