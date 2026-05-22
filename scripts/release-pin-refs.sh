#!/usr/bin/env bash
# Set the pins that only exist after the tag and the image build: the README
# `uses:` commit SHA (the tag commit) and the GitLab template image digest.
# Run by a post-build job and committed with [skip ci]. Version-only strings
# are handled earlier by release-bump-version.sh.
#
# Usage: release-pin-refs.sh <version> <commit-sha> <digest>
#   <version>     e.g. 0.3.12  (no leading v)
#   <commit-sha>  40-hex commit the release tag points at
#   <digest>      image digest, with or without the sha256: prefix
set -euo pipefail
ver="${1:?version required}"
sha="${2:?commit sha required}"
digest="${3:?image digest required}"
v="v${ver}"
hex="${digest#sha256:}"

# README: pin the action `uses:` lines to the release commit SHA and label.
sed -i.bak -E '/uses: getplumber\/plumber@/ s/@[0-9a-f]{40}([[:space:]]+# )v[0-9]+\.[0-9]+\.[0-9]+/@'"$sha"'\1'"$v"'/' README.md

# templates/plumber.yml: pin the component image digest and refresh the #vX
# note in one pass (~ delimiter to avoid clashing with the #vX comment).
sed -i.bak -E 's~(getplumber/plumber@sha256:)[a-f0-9]+(" #)v[0-9]+\.[0-9]+\.[0-9]+~\1'"$hex"'\2'"$v"'~' templates/plumber.yml

rm -f README.md.bak templates/plumber.yml.bak
echo "release-pin-refs: pinned ${v} -> sha ${sha}, digest sha256:${hex}"
