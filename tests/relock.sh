#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The conformance-relock check of the purifier contract: it relocks a copy
# of each fixture with `lein-purifier lock`, and the result must be byte
# for byte the committed lockfile. It runs as a CI job, because it needs
# the network, and it runs from any directory.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cli=$(nix build --no-link --print-out-paths "$root#cli")/bin/lein-purifier
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$root/tests/fixtures/." "$work"

for fixture in "$work"/*/; do
  name=$(basename "$fixture")
  (cd "$fixture" && "$cli" lock --force)
  if ! cmp "$root/tests/fixtures/$name/lein-purifier.lock.json" "$fixture/lein-purifier.lock.json"; then
    diff <(jq -S . "$root/tests/fixtures/$name/lein-purifier.lock.json") <(jq -S . "$fixture/lein-purifier.lock.json") || true
    echo "relock.sh: the lock of $name differs from the committed one (above)" >&2
    exit 1
  fi
done
# Ring, a project with five subprojects, at its pinned commit:
# its lockfile is kept outside its source, in tests/real/ring.
system=$(nix eval --raw --impure --expr builtins.currentSystem)
ring=$(nix build --no-link --print-out-paths "$root#checks.$system.ring-source")
cp -R "$ring" "$work/ring-source"
chmod -R u+w "$work/ring-source"
(cd "$work/ring-source" && "$cli" lock --force --lockfile "$work/ring.lock.json")
if ! cmp "$root/tests/real/ring/lein-purifier.lock.json" "$work/ring.lock.json"; then
  diff <(jq -S . "$root/tests/real/ring/lein-purifier.lock.json") <(jq -S . "$work/ring.lock.json") || true
  echo "relock.sh: the lock of Ring differs from the committed one (above)" >&2
  exit 1
fi

echo "relock.sh: passed"
