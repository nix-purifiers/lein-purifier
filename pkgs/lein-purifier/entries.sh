# SPDX-License-Identifier: MIT
#
# The part of `lein-purifier lock` that turns what a lock run left behind
# into lockfile entries. The command sources this file, and so do the unit
# tests in tests/unit.sh, which run it on local repositories and transfer
# logs they make up.

# Maven Central, and the mirror of it that a lock run downloads through.
# Maven Central answers many requests from one address with HTTP 429, and
# Google serves the same files. A file from either is locked with its URL
# at Maven Central and its URL at the mirror as the fallback.
# LEIN_PURIFIER_CENTRAL_MIRROR replaces the mirror, and an empty value
# turns it off.
centralUrl=https://repo1.maven.org/maven2/
centralMirror=${LEIN_PURIFIER_CENTRAL_MIRROR-https://maven-central.storage-download.googleapis.com/maven2/}

# The SRI SHA-256 of a file, such as sha256-D9Sn5H...=.
sriHash() {
  local hex
  hex=$(sha256sum "$1" | cut -d' ' -f1)
  # printf turns each \xHH into the byte it names.
  # shellcheck disable=SC2059,SC2001
  echo "sha256-$(printf "$(sed 's/../\\x&/g' <<<"$hex")" | base64 -w0)"
}

# The version-level SNAPSHOT metadata Maven Resolver read is the same for
# as long as the SNAPSHOT build it names exists, so it is locked as it is.
# Artifact-level metadata lists every version a repository has, and it
# gains a version with each release, so the lock writes it anew with only
# the versions the lock run downloaded. That is enough for Maven Resolver
# to pick the same version from a range offline, and the lockfile stays
# the same until a relock would pick something else.
#
# Prints the metadata of artifact directory $2 (such as org/clojure/data.json)
# of local repository $1.
artifactMetadata() {
  local m2=$1 directory=$2 group artifact versions latest
  group=$(dirname "$directory" | tr / .)
  artifact=$(basename "$directory")
  mapfile -t versions < <(cd "$m2/$directory" && find . -mindepth 1 -maxdepth 1 -type d -printf '%P\n' | sort -V)
  latest=${versions[-1]:-}
  printf '<?xml version="1.0" encoding="UTF-8"?>\n'
  printf '<metadata>\n'
  printf '  <groupId>%s</groupId>\n' "$group"
  printf '  <artifactId>%s</artifactId>\n' "$artifact"
  printf '  <versioning>\n'
  printf '    <latest>%s</latest>\n' "$latest"
  printf '    <release>%s</release>\n' "$latest"
  printf '    <versions>\n'
  printf '      <version>%s</version>\n' "${versions[@]}"
  printf '    </versions>\n'
  printf '  </versioning>\n'
  printf '</metadata>\n'
}

# lockEntries M2 TRANSFERS PROJECT ARTIFACTS REPOSITORIES [INSTALLED...]
#
# Reads the transfer log TRANSFERS of a lock run, whose lines are the
# repository URL, the resource name, the local file and the directory
# Leiningen ran in, separated by tabs, and the local repository M2 the run
# filled. A line whose repository is `seeded` names a metadata file that
# the lock run wrote into M2 from the previous lockfile, so the run keeps
# the versions it recorded; it becomes an entry as a downloaded one does. Appends one JSON entry per line to ARTIFACTS, and the path of
# each `file:` repository inside PROJECT, relative to it, to REPOSITORIES.
#
# Every logged download becomes an entry: a file with the URL it came
# from, or repository metadata with its content. A file from Maven Central
# or its mirror has both URLs; any other repository serves a released
# file at one URL, so its list of fallback URLs is empty. Files
# from a `file:` repository inside the project are not downloads; the
# build takes them from the project source.
#
# Every other file in M2 must be one Maven Resolver made itself: its
# records, the -SNAPSHOT copies of timestamped SNAPSHOT files, or a file
# under one of the INSTALLED directories (such as example/multi-lib/),
# which the lock run installed. Returns nonzero, and prints the files to
# stderr, when that is not so.
lockEntries() {
  local m2=$1 transfers=$2 project=$3 artifacts=$4 repositories=$5
  shift 5
  local installed=("$@")
  local repository resource file cwd rel path
  declare -A recorded
  if [ -n "${LEIN_PURIFIER_PROVIDED_PATHS:-}" ]; then
    while IFS= read -r rel; do recorded[$rel]=1; done < <(jq -r '.[]' "$LEIN_PURIFIER_PROVIDED_PATHS")
  fi
  while IFS=$'\t' read -r repository resource file cwd; do
    case $resource in *.sha1 | *.md5 | *.sha256 | *.sha512 | *.asc) continue ;; esac
    rel=${file#"$m2"/}
    if [[ $repository == file:* ]]; then
      path=${repository#file:}
      path=${path#//}
      if [[ $path != /* ]]; then path="$cwd/$path"; fi
      path=$(realpath -m "$path")
      case $path in
      "$project"/*) echo "${path#"$project"/}" >>"$repositories" ;;
      *)
        echo "lein-purifier: $rel came from $repository, a file: repository outside the project; move it into the project" >&2
        return 1
        ;;
      esac
      recorded[$rel]=1
      continue
    fi
    [ -z "${recorded[$rel]:-}" ] || continue
    recorded[$rel]=1
    case $(basename "$rel") in
    maven-metadata*.xml)
      if [[ $(dirname "$rel") == *-SNAPSHOT ]]; then
        jq -cn --arg path "$rel" --rawfile contents "$m2/$rel" '{ path: $path, contents: $contents }' >>"$artifacts"
      else
        jq -cn --arg path "$rel" --arg contents "$(artifactMetadata "$m2" "$(dirname "$rel")")" \
          '{ path: $path, contents: ($contents + "\n") }' >>"$artifacts"
      fi
      ;;
    *)
      if [ "$repository" = seeded ]; then
        echo "lein-purifier: $rel was seeded from the lockfile, but it is not repository metadata" >&2
        return 1
      fi
      local url="${repository%/}/$resource" mirrors=()
      if [ "${repository%/}/" = "$centralUrl" ] || { [ -n "$centralMirror" ] && [ "${repository%/}/" = "$centralMirror" ]; }; then
        url="$centralUrl$resource"
        if [ -n "$centralMirror" ]; then mirrors=("$centralMirror$resource"); fi
      fi
      jq -cn --arg path "$rel" --arg url "$url" --arg hash "$(sriHash "$m2/$rel")" \
        --argjson mirrors "$(printf '%s\n' "${mirrors[@]}" | jq -R . | jq -s 'map(select(. != ""))')" \
        '{ path: $path, url: $url, mirrors: $mirrors, hash: $hash }' >>"$artifacts"
      ;;
    esac
  done <"$transfers"

  local unexplained=() prefix explained
  while IFS= read -r rel; do
    [ -z "${recorded[$rel]:-}" ] || continue
    case $(basename "$rel") in
    _remote.repositories | *.lastUpdated | resolver-status.properties | *.sha1 | *.md5 | *.sha256 | *.sha512)
      continue
      ;;
    esac
    if [[ $(dirname "$rel") == *-SNAPSHOT && $(basename "$rel") == *-SNAPSHOT* ]]; then continue; fi
    explained=0
    for prefix in "${installed[@]}"; do
      if [[ $rel == "$prefix"* ]]; then explained=1; fi
    done
    [ $explained = 1 ] || unexplained+=("$rel")
  done < <(cd "$m2" && find . -type f -printf '%P\n' | LC_ALL=C sort)
  if [ ${#unexplained[@]} -gt 0 ]; then
    printf '  %s\n' "${unexplained[@]}" >&2
    echo "lein-purifier: the files above are in the local repository, but no download of them was logged" >&2
    return 1
  fi
}

# seedMetadata LOCKFILE M2 TRANSFERS [PACKAGE...]
#
# Writes the repository metadata entries of LOCKFILE into the local
# repository M2, and logs each in TRANSFERS as seeded, so that a lock run
# with :update :never resolves version ranges and SNAPSHOT versions to what
# LOCKFILE recorded. The metadata of each PACKAGE, given as group/name or
# as a name whose group is the same, is left out, so those packages
# resolve anew.
seedMetadata() {
  local lockFile=$1 m2=$2 transfers=$3 path directory group artifact package skip
  shift 3
  while IFS= read -r path; do
    directory=$(dirname "$path")
    # Version-level SNAPSHOT metadata lies in the version directory.
    if [[ $directory == *-SNAPSHOT ]]; then directory=$(dirname "$directory"); fi
    artifact=$(basename "$directory")
    group=$(dirname "$directory" | tr / .)
    skip=0
    for package in "$@"; do
      if [ "$package" = "$group/$artifact" ] || { [ "$package" = "$artifact" ] && [ "$group" = "$artifact" ]; }; then
        skip=1
      fi
    done
    [ $skip = 0 ] || continue
    mkdir -p "$m2/$(dirname "$path")"
    jq -j --arg path "$path" '.artifacts[] | select(.path == $path) | .contents' "$lockFile" >"$m2/$path"
    # Maven Resolver trusts a metadata file only when the
    # resolver-status.properties beside it records when it was fetched; the
    # update policy `never` then keeps it. Without that record the file
    # counts as never fetched, and the lock run fetches it again.
    printf '%s.lastUpdated=%s\n' "$(basename "$path")" "$(date +%s%3N)" \
      >>"$m2/$(dirname "$path")/resolver-status.properties"
    printf 'seeded\t%s\t%s\t%s\n' "$path" "$m2/$path" "" >>"$transfers"
  done < <(jq -r '.artifacts[] | select(has("contents")) | .path' "$lockFile")
}

# The integrity of a lockfile: the SHA-256, in hex, of every field of it in
# a fixed text form. `lein-purifier lock` stores it as `integrity`, and the
# command and the Nix builder compare it with the lockfile, so a lockfile
# edited by hand, or left with a bad merge, is refused before anything
# resolves from it. lib-overlays/default/integrity.nix computes the same text.
lockIntegrity() {
  local lockFile=$1 line path
  {
    jq -r '
      "version\t\(.version)",
      "leinVersion\t\(.leinVersion)",
      "javaMajor\t\(.javaMajor)",
      "definitionHash\t\(.definitionHash)",
      "uberjar\t\(.uberjar)",
      (.projects[] | "project\t\(.dir)\t\(.group)\t\(.name)\t\(.version)\t\(.mainClass // "")\t\(.outputs | join(","))\t\(.dependsOn | join(","))"),
      (.projectRepositories[] | "projectRepository\t\(.)"),
      (.artifacts[] | if has("contents") then "contents\t\(.path)" else "file\t\(.path)\t\(.url)\t\(.mirrors | join(" "))\t\(.hash)" end)
    ' "$lockFile" | while IFS= read -r line; do
      if [[ $line == contents$'\t'* ]]; then
        path=${line#contents$'\t'}
        printf 'contents\t%s\t%s\n' "$path" \
          "$(jq -j --arg path "$path" '.artifacts[] | select(.path == $path) | .contents' "$lockFile" | sha256sum | cut -d' ' -f1)"
      else
        printf '%s\n' "$line"
      fi
    done
  } | sha256sum | cut -d' ' -f1
}
