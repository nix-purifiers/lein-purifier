#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The conformance-offline check of the purifier contract: after
# `lein-purifier prefetch`, the everyday loop of the fixtures works with no
# network, through the `lein` of lein-purifier. It runs as a CI job,
# because the prefetch needs Nix, and it runs from any directory.
#
# The loop runs in a network namespace of its own, which has no network,
# where `unshare -rn` may make one. Elsewhere, such as in an agent sandbox
# whose only network is a proxy, it runs with the proxy variables unset.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cli=$(nix build --no-link --print-out-paths "$root#cli")/bin
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$root/tests/fixtures/." "$work"

offline() {
  if unshare -rn true 2>/dev/null; then
    unshare -rn "$@"
  else
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY "$@"
  fi
}

expect() {
  local expected=$1 output=$2
  if ! grep -qxF "$expected" <<<"$output"; then
    echo "offline.sh: expected $expected, got:" >&2
    echo "$output" >&2
    exit 1
  fi
}

for fixture in hello sources multi-sub; do
  (cd "$work/$fixture" && "$cli/lein-purifier" prefetch)
done

# A single project: run, test, and an uberjar.
cd "$work/hello"
expect '{"hello":"you"}' "$(offline "$cli/lein" run you)"
offline "$cli/lein" test
offline "$cli/lein" uberjar
test -f target/hello-1.0.0-standalone.jar

# A version range, a SNAPSHOT, a mirror and a repository inside the
# project resolve offline.
cd "$work/sources"
expect '{"greeting":"Hello from the in-project repository, sources","snapshot":true}' \
  "$(offline "$cli/lein" run)"

# In a project with subprojects, the application resolves the library
# only once `lein install` has put it into the local repository, as with
# Leiningen itself. Before that, the run fails and says what to do.
cd "$work/multi-sub/app"
if offline "$cli/lein" run 2>"$work/errors"; then
  echo "offline.sh: the application ran before its library was installed" >&2
  exit 1
fi
grep -q 'example/multi-lib is a project of this build' "$work/errors" || {
  cat "$work/errors" >&2
  exit 1
}
grep -q 'run lein install in lib ' "$work/errors" || {
  cat "$work/errors" >&2
  exit 1
}

# Once the library is installed, the application runs.
cd "$work/multi-sub/lib"
offline "$cli/lein" install
cd "$work/multi-sub/app"
expect 'MULTI-SUB!' "$(offline "$cli/lein" run)"

# A dependency the lock does not hold stops the loop, naming the command
# that fixes it.
cd "$work/hello"
sed 's|\[hiccup "1.0.5"\]|[hiccup "1.0.5"] [org.clojure/core.async "1.6.681"]|' project.clj >project.clj.new
mv project.clj.new project.clj
if offline "$cli/lein" deps 2>"$work/errors"; then
  echo "offline.sh: lein accepted a dependency the lock does not hold" >&2
  exit 1
fi
grep -q 'run lein-purifier lock' "$work/errors" || {
  cat "$work/errors" >&2
  exit 1
}

echo "offline.sh: passed"
