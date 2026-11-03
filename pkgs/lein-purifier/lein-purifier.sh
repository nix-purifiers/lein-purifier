# SPDX-License-Identifier: MIT
#
# lein-purifier: locks the downloads of a Leiningen project, prefetches
# them, and publishes the jars Nix builds. Run as `lein`, through the link
# of that name in the same package, it is the Leiningen of the everyday
# loop, which works offline on the prefetched downloads.
#
# The package sets LEIN_PURIFIER_FLAKE (the source of this flake, with its
# flake.lock), LEIN_PURIFIER_SYSTEM (the Nix system), LEIN_PURIFIER_FORMAT
# (the lock format version it reads), LEIN_PURIFIER_LEIN_VERSION (the
# version of its Leiningen), LEIN_PURIFIER_INIT (the init.clj of a lock
# run) and LEIN_PURIFIER_ENTRIES (entries.sh).

lockName=lein-purifier.lock.json

# LEIN_PURIFIER_TRACE=1 prints each command of this script as it runs.
if [ -n "${LEIN_PURIFIER_TRACE:-}" ]; then set -x; fi

# lockEntries and lockIntegrity, from pkgs/lein-purifier/entries.sh.
# shellcheck disable=SC1090,SC1091
source "$LEIN_PURIFIER_ENTRIES"

usage() {
  cat <<'EOF'
Usage:
  lein-purifier lock [--force] [--no-uberjar] [--lockfile PATH]
      Runs the build of the project, and of each subproject that lein-sub
      or lein-monolith names, with an empty local Maven repository, and
      records every file Leiningen downloads in lein-purifier.lock.json.
      Version ranges and SNAPSHOT versions keep what the lockfile
      recorded. Without --force, an up-to-date lockfile is left as it is.
  lein-purifier update [PACKAGE...] [--no-uberjar] [--lockfile PATH]
      Locks again, resolving version ranges and SNAPSHOT versions anew:
      all of them, or those of each PACKAGE, given as group/name.
  lein-purifier prefetch [--lockfile PATH]
      Fetches every locked file into the Nix store and lays them out as
      the local repository in .lein-purifier beside the lockfile, with GC
      roots there, so the everyday loop and the editor work with no
      network.
  lein-purifier publish REPOSITORY [NAME...] [--lockfile PATH]
      Builds the release of the project with Nix and deploys the jar and
      the POM of each project with `lein deploy` to REPOSITORY, a
      repository name the project or the user profile defines, or a URL.
      Without NAME, every project of the lockfile is deployed, in build
      order.
  lein ARGS...
      Leiningen, run offline on the prefetched files in a project with a
      lockfile, and as itself anywhere else. LEIN_PURIFIER_LOCKFILE names a
      lockfile outside the project, and LEIN_PURIFIER=0 runs Leiningen as
      itself.

--lockfile PATH reads or writes the lockfile at PATH, which may be outside
the project, rather than lein-purifier.lock.json at the project root.
EOF
}

die() {
  echo "lein-purifier: $*" >&2
  exit 1
}

# The nearest directory, from here upwards, that holds file $1, or nothing.
findUp() {
  local dir
  dir=$(pwd)
  while [ "$dir" != / ]; do
    if [ -f "$dir/$1" ]; then
      echo "$dir"
      return
    fi
    dir=$(dirname "$dir")
  done
}

# The project root: the nearest directory, from here upwards, that holds a
# lockfile, or else the nearest that holds project.clj. A subproject has
# its own project.clj, and the root of the build holds the lockfile.
projectRoot() {
  local root
  root=$(findUp "$lockName")
  [ -n "$root" ] || root=$(findUp project.clj)
  [ -n "$root" ] || die "no project.clj in $(pwd) or above it"
  echo "$root"
}

# The lockfile of the project at $1: the path $2 from --lockfile, when
# given, or else the path in LEIN_PURIFIER_LOCKFILE, or else
# lein-purifier.lock.json at the root.
lockFilePath() {
  if [ -n "$2" ]; then
    realpath -m "$2"
  elif [ -n "${LEIN_PURIFIER_LOCKFILE:-}" ]; then
    realpath -m "$LEIN_PURIFIER_LOCKFILE"
  else
    echo "$1/$lockName"
  fi
}

# The Leiningen user profile of a lock run, from what it needs: `mirror`
# when it downloads Maven Central through its mirror (see entries.sh), and
# `keep` when it keeps the versions the seeded metadata records.
lockProfile() {
  local mirror=$1 keep=$2 entries=""
  if [ "$mirror" = 1 ]; then
    entries=$(jq -rn --arg url "$centralMirror" '":mirrors {\"central\" {:name \"central\" :url \"\($url)\"}}"')
  fi
  if [ "$keep" = 1 ]; then entries="$entries :update :never"; fi
  echo "{:user {$entries}}"
}

# The SHA-256, in hex, of project.clj and then profiles.clj of the root and
# of each project directory given, in that order, each directory once. The
# Nix builder hashes the same files in the same order.
definitionHash() {
  local root=$1 dir seen=" "
  shift
  {
    for dir in . "$@"; do
      case $seen in *" $dir "*) continue ;; esac
      seen="$seen$dir "
      cat "$root/$dir/project.clj"
      if [ -f "$root/$dir/profiles.clj" ]; then cat "$root/$dir/profiles.clj"; fi
    done
  } | sha256sum | cut -d' ' -f1
}

# Prints the Leiningen version and the Java version, separated by a space.
# Inside a project, `lein version` would load the project and resolve its
# plugins, so it runs from the root directory.
leinVersion() {
  # "Leiningen 2.12.0 on Java 21.0.12 OpenJDK 64-Bit Server VM"
  (cd / && lein version 2>/dev/null) | sed -n 's/^Leiningen \([^ ]*\) on Java \([^ ]*\) .*/\1 \2/p'
}

# Stops with a message when the lockfile is not one `lein-purifier lock`
# wrote: when it is not JSON, as after a merge conflict, or when its
# content no longer matches its integrity, as after an edit by hand.
checkLockFile() {
  local lockFile=$1
  if ! jq -e 'type == "object"' "$lockFile" >/dev/null 2>&1; then
    die "$lockFile is not valid JSON, as when a merge conflict leaves its markers in it; run lein-purifier lock --force to write it anew"
  fi
  if [ "$(jq -r .version "$lockFile")" != "$LEIN_PURIFIER_FORMAT" ]; then
    die "$lockFile has lock format version $(jq -r .version "$lockFile"), and this lein-purifier reads version $LEIN_PURIFIER_FORMAT; run lein-purifier lock --force"
  fi
  if [ "$(jq -r '.integrity // ""' "$lockFile")" != "$(lockIntegrity "$lockFile")" ]; then
    die "$lockFile was changed after lein-purifier lock wrote it; run lein-purifier lock --force to write it anew"
  fi
}

# The major version of the Java version $1, such as 21 for 21.0.12.1. The
# lockfile records only this, so a nixpkgs update that moves the patch
# level of the JDK leaves the lockfile as it is. The JDK is the one in the
# closure of the lein-purifier package, and lein ignores JAVA_HOME and
# JAVA_CMD, so a relock on a machine with its own JDK records the same.
javaMajor() {
  echo "${1%%.*}"
}

# Whether the lockfile was made from this project definition, by this
# lock format and with this Leiningen, and is unchanged since.
lockIsCurrent() {
  local root=$1 lockFile=$2 dirs
  [ -f "$lockFile" ] || return 1
  (checkLockFile "$lockFile") 2>/dev/null || return 1
  mapfile -t dirs < <(jq -r '.projects[].dir' "$lockFile")
  [ "$(jq -r .definitionHash "$lockFile")" = "$(definitionHash "$root" "${dirs[@]}")" ] &&
    [ "$(jq -r .leinVersion "$lockFile")" = "$LEIN_PURIFIER_LEIN_VERSION" ]
}

# Stops, naming the command that fixes it, when the lockfile at $2 of the
# project at $1 is missing, malformed, edited or out of date.
requireCurrentLock() {
  local root=$1 lockFile=$2
  [ -f "$lockFile" ] || die "$lockFile does not exist; run lein-purifier lock"
  checkLockFile "$lockFile"
  lockIsCurrent "$root" "$lockFile" ||
    die "project.clj or profiles.clj changed, or Leiningen did, after $lockFile was made; run lein-purifier lock"
}

# A Nix expression that evaluates this flake from its store copy, with the
# nixpkgs it pins, so the command builds with the same library as a Nix
# build does. It is followed by an expression that uses `f` and `pkgs`.
flakeExpression() {
  printf 'let f = builtins.getFlake "path:%s"; pkgs = import f.inputs.nixpkgs { system = "%s"; overlays = [ f.overlays.default ]; }; in ' \
    "$LEIN_PURIFIER_FLAKE" "$LEIN_PURIFIER_SYSTEM"
}

# Makes .lein-purifier/home/.m2/repository, beside lockfile $2, the local
# repository of that lockfile for the project at the root $1: links to the
# locked files in the store, and links to the files of the repositories
# inside the project. Sets `home`.
#
# The files are the shared library's tree of the lockfile entries, fetched
# with the nixpkgs fetcher, which tries the mirrors of an entry when its
# URL fails. A GC root on the tree keeps them in the store, and another on
# this package keeps Leiningen and the JDK. The tree is built again only
# when the lockfile changes, so a prefetched project needs no Nix and no
# network after that.
prefetchRepository() {
  local root=$1 lockFile=$2 stamp state
  state="$(dirname "$lockFile")/.lein-purifier"
  home="$state/home"
  local m2="$home/.m2/repository" rel repository
  mkdir -p "$state"
  stamp=$(sha256sum <"$lockFile" | cut -d' ' -f1)
  if [ "$(cat "$state/stamp" 2>/dev/null || true)" != "$stamp" ] || [ ! -e "$state/repository" ]; then
    echo "lein-purifier: fetching the locked files of $lockFile" >&2
    LEIN_PURIFIER_ROOT="$root" LEIN_PURIFIER_LOCK="$lockFile" nix build --impure --out-link "$state/repository" --expr "$(flakeExpression)
      f.lib.purifier.tree {
        inherit pkgs;
        name = \"lein-purifier-repository\";
        entries = f.lib.purifier.entriesFor \"$LEIN_PURIFIER_SYSTEM\" (f.lib.purifier.checkLock (f.lib.lein-purifier.readLock {
          src = /. + builtins.getEnv \"LEIN_PURIFIER_ROOT\";
          lockFile = /. + builtins.getEnv \"LEIN_PURIFIER_LOCK\";
        }));
      }"
    # This script lies in bin/ of its package, whose closure holds
    # Leiningen and the JDK.
    nix-store --add-root "$state/toolchain" --indirect --realise "$(dirname "$(dirname "$(realpath "$0")")")" >/dev/null
    # Maven Resolver writes next to what it reads, so the local repository
    # is a writable tree of links into the store.
    rm -rf "$home"
    mkdir -p "$m2"
    cp -rs --no-preserve=mode "$state/repository/." "$m2"
    if [ "$(jq '.projectInputs // [] | length' "$lockFile")" -gt 0 ]; then
      jq '.projectInputs' "$lockFile" > "$state/inputs.json"
      python3 "$LEIN_PURIFIER_PROJECT_INPUTS_TOOL" maven --inputs "$state/inputs.json" \
        --destination "$m2" --metadata "$state/input-metadata" --roots "$state/inputs"
    fi
    echo "$stamp" >"$state/stamp"
  fi
  # Offline, Maven Resolver reads no repository but the local one, so the
  # files of each repository inside the project are linked into it, anew
  # on every run.
  while IFS= read -r repository; do
    while IFS= read -r rel; do
      mkdir -p "$m2/$(dirname "$rel")"
      ln -sfn "$root/$repository/$rel" "$m2/$rel"
    done < <(cd "$root/$repository" && find . -type f -printf '%P\n')
  done < <(jq -r '.projectRepositories[]' "$lockFile")
}

# Says what to do about a failed offline run, from the error output $2 of
# Leiningen. When the output names a project of this build, such as
# ring:ring-core in a lein-sub build, the lockfile holds no download of it,
# because the lock run installed it into the local repository, and a
# project that depends on it finds it there only after `lein install`.
# Otherwise a file the lock does not hold, which a task or profile that
# the lock run did not use may need, calls for a new lock.
explainFailure() {
  local lockFile=$1 errors=$2 group name dir hinted=0
  while IFS=$'\t' read -r group name dir; do
    if grep -q -F "$group:$name:" "$errors"; then
      echo "lein-purifier: $group/$name is a project of this build, so $lockFile holds no download of it; run lein install in $dir before the projects that depend on it (lein sub install installs the subprojects in the order :sub lists them)" >&2
      hinted=1
    fi
  done < <(jq -r '.projects[] | [.group, .name, .dir] | @tsv' "$lockFile")
  if [ $hinted = 0 ] && grep -q -E 'in offline mode|Could not transfer artifact' "$errors"; then
    echo "lein-purifier: Leiningen needs an artifact that $lockFile does not hold, perhaps for a profile or a task the lock run did not use; run lein-purifier lock --force to lock again" >&2
  fi
}

# Runs Leiningen offline on the prefetched local repository in `home`, in
# the current directory. The Leiningen home directory of the user, with its
# profiles, stays in effect. A dependency the lock does not hold fails
# offline with "in offline mode", and a copy of the error output of
# Leiningen is searched for that afterwards.
runOffline() {
  local lockFile=$1 status=0 errors
  shift
  local originalLeinHome="${LEIN_HOME:-$HOME/.lein}"
  export LEIN_HOME="$originalLeinHome"
  if [ "$(jq '.projectInputs // [] | length' "$lockFile")" -gt 0 ]; then
    export LEIN_HOME="$home/.lein"
    mkdir -p "$LEIN_HOME"
    if [ -f "$originalLeinHome/profiles.clj" ] && [ "$originalLeinHome" != "$LEIN_HOME" ]; then
      ln -sfn "$originalLeinHome/profiles.clj" "$LEIN_HOME/profiles.clj"
    fi
    : > "$LEIN_HOME/init.clj"
    if [ -f "$originalLeinHome/init.clj" ] && [ "$originalLeinHome" != "$LEIN_HOME" ]; then
      printf '(load-file %s)\n' "$(printf '%s' "$originalLeinHome/init.clj" | jq -Rs .)" >> "$LEIN_HOME/init.clj"
    fi
    cat "$LEIN_PURIFIER_PROJECTION_INIT" >> "$LEIN_HOME/init.clj"
    LEIN_PURIFIER_PROVIDED_CONFIG="$(dirname "$lockFile")/.lein-purifier/input-metadata/project-inputs.edn"
    export LEIN_PURIFIER_PROVIDED_CONFIG
  fi
  export LEIN_JVM_OPTS="-Duser.home=$home ${LEIN_JVM_OPTS:-}"
  errors=$(mktemp)
  lein -o "$@" 2> >(tee "$errors" >&2) || status=$?
  wait
  if [ $status != 0 ]; then
    explainFailure "$lockFile" "$errors"
  fi
  rm -f "$errors"
  return $status
}

# The Maven repository path of a group, such as org/clojure for
# org.clojure.
groupPath() {
  echo "${1//.//}"
}

# cmdLock MODE ARGS...
#
# MODE `lock` keeps the resolution of an existing lockfile: version ranges
# and SNAPSHOT versions resolve to what it recorded. MODE `update`
# resolves them anew, all of them, or those of the packages named in ARGS.
cmdLock() {
  local mode=$1 force=0 uberjar="" lockOption="" packages=() inputArgs=()
  shift
  if [ "$mode" = update ]; then force=1; fi
  while [ $# -gt 0 ]; do
    case $1 in
    --force) force=1 ;;
    --input)
      [ $# -ge 2 ] || die "$mode: --input needs a flake package"
      inputArgs+=(--input "$2")
      force=1
      shift
      ;;
    --no-uberjar) uberjar=false ;;
    --lockfile)
      [ $# -ge 2 ] || die "$mode: --lockfile needs a path"
      lockOption=$2
      shift
      ;;
    -*) die "$mode: unknown argument $1" ;;
    *)
      [ "$mode" = update ] || die "lock: unknown argument $1; to resolve a package anew, run lein-purifier update $1"
      packages+=("$1")
      ;;
    esac
    shift
  done

  local root lockFile previous=0
  root=$(projectRoot)
  lockFile=$(lockFilePath "$root" "$lockOption")
  if [ $force = 0 ] && lockIsCurrent "$root" "$lockFile"; then
    echo "lein-purifier: $lockFile is up to date"
    return
  fi
  # A sound previous lockfile gives the versions to keep, and its choice
  # about uberjars, unless --no-uberjar says otherwise.
  if [ -f "$lockFile" ] && (checkLockFile "$lockFile") 2>/dev/null; then previous=1; fi
  if [ -z "$uberjar" ]; then
    if [ $previous = 1 ]; then uberjar=$(jq -r .uberjar "$lockFile"); else uberjar=true; fi
  fi

  local work
  work=$(mktemp -d "${TMPDIR:-/tmp}/lein-purifier.XXXXXX")
  # The paths the lock run compares with work come normalized: Java drops
  # a doubled slash (macOS's TMPDIR ends in a slash) and realpath resolves
  # symlinks (macOS's /var is one). So work is canonical too.
  work=$(realpath "$work")
  # shellcheck disable=SC2064 # work is fixed from here on
  trap "rm -rf '$work'" EXIT
  mkdir -p "$work/project" "$work/home/.lein" "$work/java-tmp"
  # Build outputs, version control and Leiningen checkouts (links to other
  # projects on this machine) stay out of the copy, as they stay out of a
  # sandboxed build.
  tar -C "$root" --exclude=target --exclude=.git --exclude=checkouts --exclude=.lein-purifier -cf - . |
    tar -C "$work/project" -xf -
  cp "$LEIN_PURIFIER_INIT" "$work/home/.lein/init.clj"
  local previousArgs=() refreshArgs=()
  if [ "$previous" = 1 ]; then previousArgs=(--previous "$lockFile"); fi
  if [ "$mode" = update ] && [ ${#packages[@]} = 0 ]; then refreshArgs=(--refresh); fi
  python3 "$LEIN_PURIFIER_PROJECT_INPUTS_TOOL" pin \
    "${previousArgs[@]}" "${inputArgs[@]}" "${refreshArgs[@]}" --output "$work/inputs.json"
  if [ "$(jq length "$work/inputs.json")" -gt 0 ]; then
    python3 "$LEIN_PURIFIER_PROJECT_INPUTS_TOOL" maven --inputs "$work/inputs.json" \
      --destination "$work/home/.m2/repository" --metadata "$work/input-metadata" --roots "$work/inputs"
    export LEIN_PURIFIER_PROVIDED_CONFIG="$work/input-metadata/project-inputs.edn"
    export LEIN_PURIFIER_PROVIDED_PATHS="$work/input-metadata/supplied-paths.json"
    chmod u+w "$work/home/.lein/init.clj"
    cat "$LEIN_PURIFIER_PROJECTION_INIT" >> "$work/home/.lein/init.clj"
  fi

  # The lock run sees what a sandboxed build sees: an empty local
  # repository, no user profile, and none of the files in the home
  # directory. The JVM of Leiningen takes its local repository from
  # user.home, which HOME does not set. LEIN_JVM_OPTS from the caller stays
  # in effect, for proxy settings. init.clj logs every download to the
  # transfer log.
  local project="$work/project" m2="$work/home/.m2/repository" transfers="$work/transfers" versions
  export HOME="$work/home"
  export LEIN_HOME="$work/home/.lein"
  export LEIN_JVM_OPTS="-Duser.home=$work/home -Djava.io.tmpdir=$work/java-tmp ${LEIN_JVM_OPTS:-}"
  export JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=$work/java-tmp ${JAVA_TOOL_OPTIONS:-}"
  export LEIN_PURIFIER_TRANSFER_LOG="$transfers"
  : >"$transfers"
  versions=$(leinVersion)
  echo "lein-purifier: locking $root"

  # `lock` keeps what the previous lockfile resolved, and `update` with
  # package names keeps it for the other packages: the recorded metadata is
  # seeded into the local repository, and :update :never makes Maven
  # Resolver read it rather than fetch it again.
  local keep=0
  if [ $previous = 1 ] && { [ "$mode" = lock ] || [ ${#packages[@]} -gt 0 ]; }; then
    seedMetadata "$lockFile" "$m2" "$transfers" "${packages[@]}"
    keep=1
  fi
  lockProfile 0 "$keep" >"$work/home/.lein/profiles.clj"

  # The root names its subprojects, if it has any. Its plugins, such as
  # lein-sub or lein-monolith, are locked too.
  local info globs=()
  info=$(cd "$project" && lein purifier-info) || die "Leiningen could not read $root/project.clj"
  mapfile -t globs < <(awk -F'\t' '$1 == "subproject" { print $2 }' <<<"$info")

  local dirs=()
  if [ ${#globs[@]} -eq 0 ]; then
    dirs=(.)
  else
    local glob dir
    mapfile -t dirs < <(
      cd "$project" &&
        shopt -s nullglob &&
        for glob in "${globs[@]}"; do
          # The pattern is expanded as a glob, relative to the root.
          # shellcheck disable=SC2086
          printf '%s\n' $glob
        done | while IFS= read -r dir; do
          dir=${dir%/}
          dir=${dir#./}
          if [ -f "$dir/project.clj" ]; then echo "$dir"; fi
        done | awk '!seen[$0]++'
    )
    [ ${#dirs[@]} -gt 0 ] || die "the subprojects ${globs[*]} of $root match no directory with a project.clj"
  fi

  # What each project is, and which of the other projects it depends on.
  declare -A group name version main coordinates dependencies
  local dir projectInfo projectMirrors=0
  for dir in "${dirs[@]}"; do
    if [ "$dir" = . ]; then
      projectInfo=$info
    else
      projectInfo=$(cd "$project/$dir" && lein purifier-info) || die "Leiningen could not read $dir/project.clj"
    fi
    group[$dir]=$(awk -F'\t' '$1 == "project" { print $2 }' <<<"$projectInfo")
    name[$dir]=$(awk -F'\t' '$1 == "project" { print $3 }' <<<"$projectInfo")
    version[$dir]=$(awk -F'\t' '$1 == "project" { print $4 }' <<<"$projectInfo")
    main[$dir]=$(awk -F'\t' '$1 == "main" { print $2 }' <<<"$projectInfo")
    dependencies[$dir]=$(awk -F'\t' '$1 == "dependency" { print $2 "/" $3 }' <<<"$projectInfo")
    coordinates["${group[$dir]}/${name[$dir]}"]=$dir
    if grep -q '^mirror' <<<"$projectInfo"; then projectMirrors=1; fi
  done
  if grep -q '^mirror' <<<"$info"; then projectMirrors=1; fi

  # From here on, the user profile of the lock run downloads Maven Central
  # through its mirror (see entries.sh). The mirror keeps the name
  # `central`, so the metadata files keep the names that a build without
  # the mirror reads. A project that configures :mirrors itself keeps its
  # own, because Leiningen refuses two mirrors of one repository.
  if [ -n "$centralMirror" ] && [ "$projectMirrors" = 0 ]; then
    lockProfile 1 "$keep" >"$work/home/.lein/profiles.clj"
  fi

  # The build order: each project after the projects it depends on.
  local ordered=() remaining=("${dirs[@]}") next placed dependency ready
  declare -A dependsOn
  while [ ${#remaining[@]} -gt 0 ]; do
    next=()
    placed=0
    for dir in "${remaining[@]}"; do
      ready=1
      dependsOn[$dir]=""
      while IFS= read -r dependency; do
        [ -n "$dependency" ] || continue
        if [ -n "${coordinates[$dependency]:-}" ]; then
          dependsOn[$dir]+="$dependency"$'\n'
          case " ${ordered[*]} " in
          *" ${coordinates[$dependency]} "*) ;;
          *) ready=0 ;;
          esac
        fi
      done <<<"${dependencies[$dir]}"
      if [ $ready = 1 ]; then
        ordered+=("$dir")
        placed=1
      else
        next+=("$dir")
      fi
    done
    [ $placed = 1 ] || die "the projects ${next[*]} depend on each other in a cycle"
    remaining=("${next[@]}")
  done

  # Each project builds the way a sandboxed build builds it. In a project
  # with subprojects, each one is installed into the local repository, so
  # the projects after it resolve it from there.
  # Each task that builds a jar first empties target/ (:auto-clean), so
  # `install`, which builds the jar it installs, comes before `uberjar`.
  # The builder runs the same tasks.
  local tasks multi=false
  if [ ${#globs[@]} -gt 0 ]; then multi=true; fi
  if [ $multi = true ]; then tasks="install,"; else tasks="jar,"; fi
  if [ "$uberjar" = true ]; then tasks="$tasks uberjar,"; fi
  tasks="$tasks pom"
  local projects="$work/projects.jsonl" log canonical outputs mainClass standalone
  : >"$projects"
  for dir in "${ordered[@]}"; do
    log="$work/log-${dir//\//_}"
    echo "lein-purifier: building $dir"
    # Inside an if condition, errexit does not apply, so the steps are
    # joined with &&. The task list splits into words, and `do` is the
    # Leiningen task.
    # shellcheck disable=SC2086,SC1010
    if ! (cd "$project/$dir" && lein with-profile +test deps && lein do $tasks) 2>&1 | tee "$log"; then
      die "the lock run of $dir failed; see the output above"
    fi
    canonical=$(cd "$project/$dir" && pwd)
    # Byte order keeps the lockfile the same under every locale.
    outputs=$(sed -n "s|^Created $canonical/||p" "$log" | LC_ALL=C sort -u | jq -R . | jq -s .)
    # The main class is the one the uberjar manifest names, for a project
    # with :main. Without :main, the manifest names clojure.main, which
    # would make the launcher of a library a Clojure REPL.
    mainClass=null
    standalone=$(jq -r '.[] | select(endswith("-standalone.jar"))' <<<"$outputs")
    if [ -n "$standalone" ] && [ -n "${main[$dir]}" ]; then
      # unzip exits nonzero on warnings, and a jar without a manifest has no
      # main class, so its status does not count.
      mainClass=$({ unzip -p "$project/$dir/$standalone" META-INF/MANIFEST.MF 2>/dev/null || true; } |
        tr -d '\r' | sed -n 's/^Main-Class: *//p' | jq -R . | jq -s 'first // null')
    fi
    jq -cn --arg dir "$dir" --arg group "${group[$dir]}" --arg name "${name[$dir]}" \
      --arg version "${version[$dir]}" --argjson mainClass "$mainClass" --argjson outputs "$outputs" \
      --argjson dependsOn "$(printf '%s' "${dependsOn[$dir]}" | jq -R . | jq -s 'map(select(. != ""))')" \
      '{ dir: $dir, group: $group, name: $name, version: $version, mainClass: $mainClass,
         outputs: $outputs, dependsOn: $dependsOn }' >>"$projects"
  done

  # The projects of this build that the lock run installed are not
  # downloads. That covers the maven-metadata-local.xml beside their
  # versions too.
  local installed=() artifacts="$work/artifacts.jsonl" repositories="$work/repositories"
  if [ $multi = true ]; then
    for dir in "${ordered[@]}"; do
      installed+=("$(groupPath "${group[$dir]}")/${name[$dir]}/")
    done
  fi
  : >"$artifacts"
  : >"$repositories"
  lockEntries "$m2" "$transfers" "$project" "$artifacts" "$repositories" "${installed[@]}" ||
    die "the lock run left files that cannot be locked (above)"

  jq -n \
    --argjson version "$LEIN_PURIFIER_FORMAT" \
    --arg leinVersion "${versions%% *}" \
    --arg javaMajor "$(javaMajor "${versions#* }")" \
    --arg definitionHash "$(definitionHash "$root" "${ordered[@]}")" \
    --argjson uberjar "$uberjar" \
    --argjson projectRepositories "$(LC_ALL=C sort -u "$repositories" | jq -R . | jq -s .)" \
    --slurpfile projectInputs "$work/inputs.json" \
    --slurpfile projects "$projects" \
    --slurpfile artifacts "$artifacts" \
    '{
      version: $version,
      leinVersion: $leinVersion,
      javaMajor: $javaMajor,
      definitionHash: $definitionHash,
      uberjar: $uberjar,
      projects: $projects,
      projectRepositories: $projectRepositories,
      artifacts: ($artifacts | sort_by(.path))
    } | if ($projectInputs[0] | length) > 0 then . + {projectInputs: $projectInputs[0]} else . end' >"$work/lock.json"
  jq --arg integrity "$(lockIntegrity "$work/lock.json")" '. + { integrity: $integrity }' \
    "$work/lock.json" >"$lockFile.tmp"
  mv "$lockFile.tmp" "$lockFile"
  echo "lein-purifier: wrote $lockFile ($(jq '.projects | length' "$lockFile") projects, $(jq '.artifacts | length' "$lockFile") entries)"
}

# Splits the arguments of a command into --lockfile PATH, which it sets as
# `lockOption`, and the rest, which it sets as `rest`.
lockfileOption() {
  lockOption=""
  rest=()
  while [ $# -gt 0 ]; do
    if [ "$1" = --lockfile ]; then
      [ $# -ge 2 ] || die "--lockfile needs a path"
      lockOption=$2
      shift 2
    else
      rest+=("$1")
      shift
    fi
  done
}

cmdPrefetch() {
  local lockOption rest root lockFile home
  lockfileOption "$@"
  [ ${#rest[@]} -eq 0 ] || die "prefetch: unknown argument ${rest[0]}"
  root=$(projectRoot)
  lockFile=$(lockFilePath "$root" "$lockOption")
  requireCurrentLock "$root" "$lockFile"
  prefetchRepository "$root" "$lockFile"
  echo "lein-purifier: prefetched $lockFile into $(dirname "$lockFile")/.lein-purifier"
}

cmdPublish() {
  local lockOption rest root lockFile home
  lockfileOption "$@"
  [ ${#rest[@]} -ge 1 ] || die "publish: name the repository to deploy to"
  local repository=${rest[0]} names=("${rest[@]:1}")
  root=$(projectRoot)
  lockFile=$(lockFilePath "$root" "$lockOption")
  requireCurrentLock "$root" "$lockFile"
  if [ ${#names[@]} -eq 0 ]; then
    mapfile -t names < <(jq -r '.projects[].name' "$lockFile")
  fi
  prefetchRepository "$root" "$lockFile"

  # The release is the one buildLeinProject builds, with the nixpkgs this
  # flake pins, so its Leiningen is the one the lock was made with.
  local release_json release catalog
  echo "lein-purifier: building the immutable publication repository with Nix"
  release_json=$(LEIN_PURIFIER_ROOT="$root" LEIN_PURIFIER_LOCK="$lockFile" nix build --impure --json \
    --out-link "$(dirname "$lockFile")/.lein-purifier/release" --expr "$(flakeExpression)
      let built = pkgs.lein-purifier.buildLeinProject {
        src = /. + builtins.getEnv \"LEIN_PURIFIER_ROOT\";
        lockFile = /. + builtins.getEnv \"LEIN_PURIFIER_LOCK\";
      }; in [ built.projections.maven built.projections.maven.metadata ]")
  release=$(jq -r '.[0].outputs.out' <<< "$release_json")
  catalog="$(jq -r '.[0].outputs.metadata' <<< "$release_json")/catalog.json"

  local name record dir group version directory module files=()
  while IFS= read -r module; do
    name=$(jq -r .name <<< "$module")
    group=$(jq -r .group <<< "$module")
    version=$(jq -r .version <<< "$module")
    record=$(jq -c --arg group "$group" --arg name "$name" \
      '[.projects[] | select(.group == $group and .name == $name)] | first // {dir:"."}' "$lockFile")
    dir=$(jq -r .dir <<< "$record")
    directory="$release/$(groupPath "$group")/$name/$version"
    mapfile -t files < <(find "$directory" -maxdepth 1 -type f \
      ! -name '*.sha1' ! -name '*.md5' ! -name '*.sha256' ! -name '*.sha512' ! -name '*.asc' | LC_ALL=C sort)
    echo "lein-purifier: deploying $group/$name $version to $repository"
    (cd "$root/$dir" &&
      LEIN_HOME="${LEIN_HOME:-$HOME/.lein}" LEIN_JVM_OPTS="-Duser.home=$home ${LEIN_JVM_OPTS:-}" \
        lein deploy "$repository" "$group/$name" "$version" "${files[@]}")
  done < <(jq -c --argjson names "$(printf '%s\n' "${names[@]}" | jq -R . | jq -s .)" \
    --slurpfile lock "$lockFile" '
    (.publications // .modules)[] | . as $module | select(
      ($names | index($module.name)) != null or
      ([$lock[0].projects[] | (.group + ":" + .name)] | index($module.group + ":" + $module.name)) == null
    )' "$catalog")
}

# The `lein` of the everyday loop. In a project with a lockfile, it runs
# Leiningen offline on the prefetched files, after a prefetch when the
# lockfile changed. Anywhere else, and with LEIN_PURIFIER=0, it is
# Leiningen itself.
leinWrapper() {
  local root lockFile home
  if [ "${LEIN_PURIFIER:-1}" = 0 ]; then exec lein "$@"; fi
  if [ -n "${LEIN_PURIFIER_LOCKFILE:-}" ]; then
    lockFile=$(realpath -m "$LEIN_PURIFIER_LOCKFILE")
    root=$(findUp project.clj)
    [ -n "$root" ] || exec lein "$@"
  else
    root=$(findUp "$lockName")
    if [ -z "$root" ]; then
      echo "lein-purifier: warning: no lein-purifier.lock.json found; running lein impurely. Run \`lein-purifier lock\` to use Nix-resolved dependencies." >&2
      exec lein "$@"
    fi
    lockFile="$root/$lockName"
  fi
  requireCurrentLock "$root" "$lockFile"
  prefetchRepository "$root" "$lockFile"
  runOffline "$lockFile" "$@"
}

if [ "$(basename "$0")" = lein ]; then
  leinWrapper "$@"
  exit
fi

case ${1:-} in
lock)
  shift
  cmdLock lock "$@"
  ;;
update)
  shift
  cmdLock update "$@"
  ;;
prefetch)
  shift
  cmdPrefetch "$@"
  ;;
publish)
  shift
  cmdPublish "$@"
  ;;
-h | --help | help)
  usage
  ;;
*)
  usage >&2
  exit 1
  ;;
esac
