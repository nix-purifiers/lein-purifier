# SPDX-License-Identifier: MIT
#
# buildLeinProject: the sandboxed builds of a Leiningen project, from the
# lockfile `lein-purifier lock` writes at the project root.
#
# The file is a package for callPackage. The first argument set is what it
# takes by name, and the result is the builder. The flake's
# `overlays.default` adds the scope `pkgs.lein-purifier`, made with
# lib.makeScope, and the builder is a package in that scope. A package
# written for callPackage takes the scope by name,
# `buildLeinProject.override` replaces what the builder takes, and
# `lein-purifier.overrideScope` replaces what the scope shares:
#
#   { lein-purifier }: (lein-purifier.buildLeinProject { src = ./.; }).packages.hello
#
# The builder takes `src`, `lockFile`, `fetchers`, `jdk` and `srcFilter`.
# Its result has, by the purifier contract,
#
#   packages.<name>  the package of each project of the lock, named as the
#                    project is: the root project, or each subproject that
#                    lein-sub or lein-monolith names. A package holds the
#                    jar, the uberjar and the POM in share/java, and for a
#                    project with :main, a launcher in bin.
#   tests            the test run (`lein test`) of every project, in the
#                    sandbox
#   release          what `lein-purifier publish` deploys: the jar and the
#                    POM of every project, in Maven repository layout
#   fetches          the entries of the lock in memory (readLock)
#
# and also `lock`, the lockfile as builtins.fromJSON reads it, `dependencies`, the
# local Maven repository of every entry, and `jdk`.
{
  lib,
  stdenvNoCC,
  runCommand,
  linkFarm,
  python3,
  fetchurl,
  makeWrapper,
  strip-nondeterminism,
  # The JDKs a build can run on. The default JDK of a build is the headless
  # one of the major version its lock was made with.
  javaPackages,
  leiningen,
  # The shared library of the nix-purifiers.
  purifier,
}:
{
  # The project root, which holds project.clj.
  src,
  # Passed to the shared library's fetchEntry and tree, such as a
  # `fetchurl` that sends credentials or uses a company mirror.
  fetchers ? { },
  # Nix-built JVM projects, selected from their native repository catalogs.
  projectDependencies ? purifier.lockedProjectInputs {
    inputs = (builtins.fromJSON (builtins.readFile lockFile)).projectInputs or [ ];
    system = stdenvNoCC.hostPlatform.system;
  },
  # The lockfile. The default is the one `lein-purifier lock` writes at the
  # project root, and a lockfile outside `src` takes its place.
  lockFile ? src + "/lein-purifier.lock.json",
  # The JDK that runs Leiningen and the JVMs of the project. The default
  # is the headless JDK of the major version the lock was made with.
  jdk ? null,
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out build outputs, editor
  # state and Leiningen checkouts.
  srcFilter ? null,
}:
let
  # The lock in memory (read-lock.nix). Each Leiningen version adds its own
  # nREPL dependencies to every project, so a lock made with another
  # Leiningen does not hold them, which is a problem only the builder,
  # with its Leiningen, can find. checkLock stops the build before it
  # starts when there is any problem.
  inMemory = import ../../lib-overlays/default/read-lock.nix { inherit lib; } {
    inherit src lockFile;
  };
  # The lockfile itself, for what only lein-purifier needs: the Leiningen
  # and Java versions, the projects in build order and the repositories
  # inside the project. It is read once readLock found it sound.
  raw = builtins.fromJSON (builtins.readFile lockFile);
  leinProblem =
    lib.optional (inMemory.problems == [ ] && raw.leinVersion != leiningen.version)
      "lein-purifier: ${toString lockFile} was made with Leiningen ${raw.leinVersion}, and this nixpkgs has Leiningen ${leiningen.version}; run `lein-purifier lock` with the lein-purifier of this nixpkgs, or use the nixpkgs input of lein-purifier.";
  checked = purifier.checkLock (inMemory // { problems = inMemory.problems ++ leinProblem; });
  lock = builtins.seq checked raw;

  defaultSrcFilter =
    path: type:
    let
      name = baseNameOf path;
    in
    !(
      (
        type == "directory"
        && (
          name == "target"
          || name == "checkouts"
          || name == ".lein-purifier"
          || name == ".cpcache"
          || name == ".lsp"
          || name == ".clj-kondo"
        )
      )
      || name == ".git"
      || name == ".idea"
      || name == ".nrepl-port"
      || lib.hasPrefix "result" name
    );

  filteredSrc = builtins.path {
    path = src;
    name = "lein-source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  javaMajor = lock.javaMajor;
  defaultJdk =
    javaPackages.compiler."openjdk${javaMajor}".headless
      or (throw "lein-purifier: javaPackages has no openjdk${javaMajor}, the JDK major version the lock was made with; pass `jdk`.");
  jdk' = if jdk != null then jdk else defaultJdk;

  # The nixpkgs leiningen wrapper exports the JAVA_CMD it was built with,
  # so the JDK is chosen through the override.
  leinWithJdk = leiningen.override { jdk = jdk'; };

  dependencies = purifier.tree (
    {
      inherit fetchurl runCommand;
      name = "lein-purifier-repository";
      entries = purifier.entriesFor stdenvNoCC.hostPlatform.system checked;
    }
    // fetchers
  );

  provided = purifier.jvmProjections {
    repository = null;
    dependencies = projectDependencies;
    inherit runCommand python3;
    name = "lein-provided-dependencies";
  };

  # The tasks of the lock run. A lock with subprojects installs each one
  # into the local repository, and `install` builds the jar it installs.
  # Each task that builds a jar first empties target/ (:auto-clean), so
  # `uberjar` comes after it.
  multi = (builtins.head lock.projects).dir != ".";
  tasks = [
    (if multi then "install" else "jar")
  ]
  ++ lib.optional lock.uberjar "uberjar"
  ++ [ "pom" ];

  javaDirectory = "share/java";
  groupPath = group: lib.replaceStrings [ "." ] [ "/" ] group;
  coordinate = project: "${project.group}/${project.name}";
  jarOutput =
    project:
    lib.findFirst (
      o: lib.hasSuffix ".jar" o && !lib.hasSuffix "-standalone.jar" o
    ) null project.outputs;
  uberjarOutput = project: lib.findFirst (lib.hasSuffix "-standalone.jar") null project.outputs;
  base = project: "${project.name}-${project.version}";

  projectsByCoordinate = builtins.listToAttrs (
    map (p: {
      name = coordinate p;
      value = p;
    }) lock.projects
  );

  # Links the jar and the POM of a project built before this one into the
  # local repository, at the paths `lein install` puts them.
  linkProject =
    dependency:
    let
      project = projectsByCoordinate.${dependency};
      package = packages.${project.name};
      directory = "$HOME/.m2/repository/${groupPath project.group}/${project.name}/${project.version}";
    in
    ''
      mkdir -p "${directory}"
      ln -s ${package}/${javaDirectory}/${baseNameOf (jarOutput project)} "${directory}/${base project}.jar"
      ln -s ${package}/${javaDirectory}/${base project}.pom "${directory}/${base project}.pom"
    '';

  # What every build of a project does before Leiningen runs.
  # `lein-purifier lock` runs Leiningen the same way, so a lock made with
  # it holds what this needs: the local repository is the only one, it is
  # read offline, and no user profile applies.
  setUp = project: ''
    # A dependency the lock does not hold fails offline with "in offline
    # mode"; the build then says what to do about it.
    leinOffline() {
      if ! "$@" 2> >(tee "$TMPDIR/lein-errors" >&2); then
        wait
        if grep -q 'in offline mode' "$TMPDIR/lein-errors"; then
          echo "lein-purifier: Leiningen needs an artifact that the lockfile does not hold; run lein-purifier lock --force" >&2
        fi
        return 1
      fi
    }
    export HOME="$TMPDIR/home"
    export LEIN_HOME="$HOME/.lein"
    mkdir -p "$HOME/.m2/repository" "$LEIN_HOME" "$TMPDIR/java-tmp"
    cp --no-preserve=mode ${./runtime-classpath.clj} "$LEIN_HOME/init.clj"
    # Maven Resolver writes next to what it reads, so the repository is a
    # writable tree of links into the store.
    cp -rs --no-preserve=mode ${dependencies}/. "$HOME/.m2/repository"
    ${lib.optionalString (projectDependencies != [ ]) ''
      cp -r --remove-destination --no-preserve=mode ${provided.maven}/. "$HOME/.m2/repository"
      export LEIN_PURIFIER_PROVIDED_CONFIG="$TMPDIR/nix-project-inputs.edn"
      ${python3}/bin/python ${purifier.jvmRepositoryTool} \
        --clojure-config --catalog ${provided.maven.catalog} > "$LEIN_PURIFIER_PROVIDED_CONFIG"
      cat ${./project-inputs.clj} >> "$LEIN_HOME/init.clj"
    ''}
    # Offline, Maven Resolver reads no repository but the local one, so the
    # files of each repository inside the project join it.
    ${lib.concatMapStrings (repository: ''
      cp -rs --no-preserve=mode "$PWD/${repository}/." "$HOME/.m2/repository"
    '') lock.projectRepositories}
    ${lib.concatMapStrings linkProject project.dependsOn}
    # The JVM of Leiningen takes its local repository from user.home,
    # which HOME does not set. The JVMs of the project take their temporary
    # directory from JAVA_TOOL_OPTIONS.
    export LEIN_JVM_OPTS="-Duser.home=$HOME -Djava.io.tmpdir=$TMPDIR/java-tmp"
    # The Clojure compiler orders the fields of a closure by the identity
    # hash codes of its locals, which differ from one JVM run to the next,
    # so ahead-of-time compiled classes would differ between builds. With
    # every identity hash code the same, the order is the order the
    # compiler meets the locals in, and a rebuild gives the same classes.
    export JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=$TMPDIR/java-tmp -XX:+UnlockExperimentalVMOptions -XX:hashCode=2"
    cd ${lib.escapeShellArg project.dir}
  '';

  mkPackage =
    project:
    let
      uberjar = uberjarOutput project;
      launcher = project.mainClass != null && uberjar != null;
    in
    stdenvNoCC.mkDerivation (finalAttrs: {
      pname = project.name;
      inherit (project) version;
      src = filteredSrc;
      nativeBuildInputs = [
        jdk'
        leinWithJdk
        strip-nondeterminism
      ]
      ++ lib.optional launcher makeWrapper;
      dontConfigure = true;
      preBuild = setUp project;
      buildPhase = ''
        runHook preBuild
        leinOffline lein -o do ${lib.concatStringsSep ", " tasks}
                  leinOffline lein -o purifier-runtime-classpath > "$TMPDIR/runtime-classpath.txt"
        runHook postBuild
      '';
      dontFixup = !launcher;
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/${javaDirectory}"
        for output in ${lib.escapeShellArgs project.outputs}; do
          if [ ! -f "$output" ]; then
            echo "lein-purifier: the lock names $output, which this build of ${project.name} did not produce; run lein-purifier lock --force" >&2
            exit 1
          fi
          cp "$output" "$out/${javaDirectory}/"
        done
        cp pom.xml "$out/${javaDirectory}/${base project}.pom"
        # A jar records the time each entry was written; stripping it makes
        # a rebuild give the same bytes.
        strip-nondeterminism "$out/${javaDirectory}"/*.jar
                  ${python3}/bin/python ${./export-runtime.py} ${purifier.projectInputsTool} \
            "$TMPDIR/runtime-classpath.txt" "$PWD" "$HOME/.m2/repository" \
            ${provided.maven.catalog} "$out/nix-support/runtime"
        ${lib.optionalString launcher ''
          makeWrapper ${jdk'}/bin/java "$out/bin/${project.name}" \
            --add-flags "-jar $out/${javaDirectory}/${baseNameOf uberjar}"
        ''}
        runHook postInstall
      '';
      passthru = {
        leinProject = project;
        projections = purifier.jvmProjections {
          repository = release;
          inherit runtimeRepository;
          dependencies = projectDependencies;
          inherit runCommand python3;
          name = "lein-jvm-publications";
        };
        # The files of the package by file name, such as
        # artifacts."hello-1.0.0-standalone.jar". They are known from the
        # lock alone, before the package is built.
        artifacts = builtins.listToAttrs (
          map (output: {
            name = baseNameOf output;
            value = "${finalAttrs.finalPackage}/${javaDirectory}/${baseNameOf output}";
          }) project.outputs
        );
      };
      meta = {
        description = "${project.group}/${project.name}, built by lein-purifier";
      }
      // lib.optionalAttrs launcher { mainProgram = project.name; };
    });

  # The test run of a project: `lein test`, offline, after the projects it
  # depends on are built.
  mkTest =
    project:
    stdenvNoCC.mkDerivation {
      name = "${project.name}-tests";
      src = filteredSrc;
      nativeBuildInputs = [
        jdk'
        leinWithJdk
      ];
      dontConfigure = true;
      preBuild = setUp project;
      buildPhase = ''
        runHook preBuild
        leinOffline lein -o test
        runHook postBuild
      '';
      installPhase = "touch $out";
    };

  packages = builtins.listToAttrs (
    map (project: {
      inherit (project) name;
      value = mkPackage project;
    }) lock.projects
  );

  tests = linkFarm "lein-purifier-tests" (
    map (project: {
      inherit (project) name;
      path = mkTest project;
    }) lock.projects
  );

  runtimeRepository = runCommand "lein-runtime-repository" { } ''
    ${python3}/bin/python ${./merge-runtime.py} ${purifier.projectInputsTool} "$out" \
      ${lib.escapeShellArgs (
        map (package: "${package}/nix-support/runtime") (builtins.attrValues packages)
      )}
  '';

  release = runCommand "lein-purifier-release" { } (
    lib.concatMapStrings (
      project:
      let
        directory = "$out/${groupPath project.group}/${project.name}/${project.version}";
        package = packages.${project.name};
      in
      ''
        mkdir -p "${directory}"
        ln -s ${package}/${javaDirectory}/${baseNameOf (jarOutput project)} "${directory}/${base project}.jar"
        ln -s ${package}/${javaDirectory}/${base project}.pom "${directory}/${base project}.pom"
      ''
    ) lock.projects
  );
in
{
  projections = purifier.jvmProjections {
    repository = release;
    inherit runtimeRepository;
    dependencies = projectDependencies;
    inherit runCommand python3;
    name = "lein-jvm-publications";
  };
  inherit
    lock
    dependencies
    packages
    tests
    release
    ;
  fetches = checked.entries;
  jdk = jdk';
}
