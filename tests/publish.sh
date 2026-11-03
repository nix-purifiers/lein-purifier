#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Tests `lein-purifier publish` on copies of the hello and multi-sub
# fixtures: each deploys to a repository in a temporary directory, and the
# deployed jars and POMs must be the ones of the release Nix built. It
# needs the Nix daemon, and it runs from any directory.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cli=$(nix build --no-link --print-out-paths "$root#cli")/bin/lein-purifier
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$root/tests/fixtures/hello" "$root/tests/fixtures/multi-sub" "$work"

# The repository `test` is a directory. A Leiningen home of its own
# defines it, with signing off, since the test has no key to sign with.
mkdir -p "$work/lein-home"
cat >"$work/lein-home/profiles.clj" <<EOF
{:user {:deploy-repositories [["test" {:url "file://$work/deployed" :sign-releases false}]]}}
EOF

(cd "$work/hello" && LEIN_HOME="$work/lein-home" "$cli" publish test)
(cd "$work/multi-sub" && LEIN_HOME="$work/lein-home" "$cli" publish test)

compare() {
  local project=$1 path=$2
  cmp "$work/deployed/$path" "$work/$project/.lein-purifier/release/$path"
}
for project in hello multi-sub; do
  while IFS= read -r path; do
    compare "$project" "$path"
  done < <(cd "$work/$project/.lein-purifier/release" && find . -type f \( -name '*.jar' -o -name '*.pom' \) | sed 's|^\./||')
done
echo "publish.sh: passed"
