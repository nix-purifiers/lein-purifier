# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked artifacts. The conformance
# checks of the purifier contract that need Nix or the network outside
# the sandbox (conformance-relock, conformance-rebuild and
# conformance-offline) are CI jobs; see .github/workflows/check.yml.
{
  pkgs,
  # The flake's library, with `lein-purifier` and the shared `purifier`.
  lib,
  # The flake's default package overlay, which adds the scope lein-purifier.
  overlay,
  # The lein-purifier command.
  cli,
}:
let
  # Every fixture builds the way a consumer's package does: through the
  # builder that the overlay adds to the package set.
  withOverlay = pkgs.extend overlay;
  build = withOverlay.lein-purifier.buildLeinProject;

  # An application with dependencies from Maven Central and Clojars, a
  # plugin, a test profile and an uberjar with a main class.
  hello = build { src = ./fixtures/hello; };

  # Dependencies from a version range, a SNAPSHOT and a repository inside
  # the project, with Maven Central reached through a mirror that
  # profiles.clj configures.
  sources = build { src = ./fixtures/sources; };

  # Subprojects: lein-sub names them in :sub, lein-monolith in its
  # :project-dirs. In each, the application depends on the library.
  multi-sub = build { src = ./fixtures/multi-sub; };
  monolith = build { src = ./fixtures/monolith; };

  # Ring, a well-known Leiningen project with five subprojects that lein-sub
  # names, pinned to a commit. Its lockfile is kept outside its source, as
  # a packaging flake keeps it for a project it does not change.
  # The builder reads project.clj during evaluation, so the source must
  # already be a tree rather than an output requiring a foreign-system build.
  ringSource = builtins.fetchTarball {
    url = "https://github.com/ring-clojure/ring/archive/6238fe0e2e4506e28a0ce6ade9ae514f7b02cbee.tar.gz";
    sha256 = "0hv2g5gy48qj0czg7h1ikkr6bp5ymdl5a2jx1qknrlkx79k8174d";
  };
  ring = build {
    src = ringSource;
    lockFile = ./real/ring/lein-purifier.lock.json;
  };

  # A check that runs a launcher and compares its output with one line.
  runs =
    name: package: expected:
    pkgs.runCommand name { } ''
      ${lib.getExe package} > output
      if ! grep -qxF ${lib.escapeShellArg expected} output; then
        echo "${name}: expected ${expected}, got:" >&2
        cat output >&2
        exit 1
      fi
      touch $out
    '';

  # A check that there are messages, and that each is a refusal naming the
  # command to run.
  namesCommand =
    name: messages:
    assert messages != [ ] && lib.all (lib.hasInfix "lein-purifier lock") messages;
    pkgs.runCommand name { } "touch $out";

  helloLockFile = ./fixtures/hello/lein-purifier.lock.json;
  helloLock = builtins.fromJSON (builtins.readFile helloLockFile);
  writeLock = lock: builtins.toFile "lein-purifier.lock.json" (builtins.toJSON lock);

  # A copy of the hello lock with some fields changed, which keeps the old
  # integrity, as an edit by hand would.
  helloLockWith = attrs: writeLock (helloLock // attrs);

  # The same, with the integrity of the changed lock, as `lein-purifier
  # lock` would write it.
  helloLockRewritten =
    attrs:
    let
      lock = helloLock // attrs;
    in
    writeLock (lock // { integrity = import ../nix/lib/integrity.nix lock; });

  # The problems of the lock in memory of the hello project, with this
  # lockfile.
  problemsOf =
    lockFile:
    (lib.lein-purifier.readLock {
      src = ./fixtures/hello;
      inherit lockFile;
    }).problems;

  # Whether the builder refuses the hello project with this lockfile when
  # it is evaluated.
  refuses =
    lockFile:
    !(builtins.tryEval
      (build {
        src = ./fixtures/hello;
        inherit lockFile;
      }).packages.hello.drvPath
    ).success;

  # The hello lock without the Clojars jar of hiccup.
  withoutHiccupJar = {
    artifacts = builtins.filter (
      a: a.path != "hiccup/hiccup/1.0.5/hiccup-1.0.5.jar"
    ) helloLock.artifacts;
  };
in
{
  # A producer needs a complete runtime view even with no Nix project inputs.
  standalone-projection = pkgs.runCommand "lein-standalone-projection" { } ''
    test -n "$(find ${hello.projections.maven}/org/clojure/data.json -name '*.jar')"
    touch $out
  '';
  composition = import ./composition.nix {
    inherit pkgs build;
    purifier = withOverlay.lib.purifier;
  };

  jvm-projection = hello.packages.hello.projections.maven;

  inherit cli;

  # The unit tests of the lock run's parsing.
  unit =
    pkgs.runCommand "unit"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.findutils
          pkgs.gnused
          pkgs.gawk
          pkgs.python3
        ];
      }
      ''
        bash ${./unit.sh} ${../pkgs/lein-purifier/entries.sh}
        python3 -B ${./java-major.py} ${../pkgs/lein-purifier/lein-purifier.sh}
        touch $out
      '';

  # The package of each fixture project, which tests/rebuild.sh rebuilds.
  hello = hello.packages.hello;
  sources = sources.packages.sources;
  multi-lib = multi-sub.packages.multi-lib;
  multi-app = multi-sub.packages.multi-app;
  mono-core = monolith.packages.mono-core;
  mono-tool = monolith.packages.mono-tool;

  hello-tests = hello.tests;
  hello-runs = runs "hello-runs" hello.packages.hello ''{"hello":"world"}'';

  # The lock names every file of the package before it is built, each one
  # is in the package, and the release holds the jar and the POM in Maven
  # repository layout.
  hello-artifacts = pkgs.runCommand "hello-artifacts" { } ''
    test -f ${hello.packages.hello.artifacts."hello-1.0.0.jar"}
    test -f ${hello.packages.hello.artifacts."hello-1.0.0-standalone.jar"}
    test -f ${hello.packages.hello}/share/java/hello-1.0.0.pom
    test -f ${hello.release}/example/hello/1.0.0/hello-1.0.0.jar
    test -f ${hello.release}/example/hello/1.0.0/hello-1.0.0.pom
    ${lib.optionalString (
      builtins.length hello.fetches != builtins.length helloLock.artifacts
    ) "exit 1"}
    touch $out
  '';

  sources-runs =
    runs "sources-runs" sources.packages.sources
      ''{"greeting":"Hello from the in-project repository, sources","snapshot":true}'';

  multi-sub-runs = runs "multi-sub-runs" multi-sub.packages.multi-app "MULTI-SUB!";
  multi-sub-tests = multi-sub.tests;

  monolith-runs =
    runs "monolith-runs" monolith.packages.mono-tool
      "mono-tool is built from a monolith";
  monolith-release = monolith.release;

  # A lockfile older than the project fails, naming the command to run:
  # one made from another project definition, which readLock reports, or
  # with another Leiningen, which the builder reports.
  conformance-stale =
    let
      stale = helloLockRewritten { definitionHash = "0000"; };
      otherLein = helloLockRewritten { leinVersion = "0.0.0"; };
    in
    assert refuses stale && refuses otherLein;
    namesCommand "conformance-stale" (problemsOf stale);

  # A lockfile with a changed hash fails, naming the command to run.
  conformance-tampered =
    let
      tampered = helloLockWith {
        artifacts = map (
          a: if a ? hash then a // { hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; } else a
        ) helloLock.artifacts;
      };
    in
    assert refuses tampered;
    namesCommand "conformance-tampered" (problemsOf tampered);

  # A lockfile without a needed entry fails, naming the command to run:
  # an edited one at evaluation, and one that is otherwise sound when
  # Leiningen fails offline.
  conformance-missing =
    let
      failure =
        pkgs.testers.testBuildFailure
          (build {
            src = ./fixtures/hello;
            lockFile = helloLockRewritten withoutHiccupJar;
          }).packages.hello;
    in
    assert problemsOf (helloLockWith withoutHiccupJar) != [ ];
    pkgs.runCommand "conformance-missing" { } ''
      grep -q 'in offline mode' ${failure}/testBuildFailure.log
      grep -q 'run lein-purifier lock --force' ${failure}/testBuildFailure.log
      touch $out
    '';

  # A lockfile that is not valid fails, naming the command to run: one
  # with merge conflict markers, one that is not a lockfile, and one of
  # another format.
  conformance-malformed =
    let
      conflicted = builtins.toFile "lein-purifier.lock.json" ''
        <<<<<<< HEAD
        ${builtins.readFile helloLockFile}
        =======
        { }
        >>>>>>> other
      '';
      notALock = builtins.toFile "lein-purifier.lock.json" "{ }";
      otherFormat = helloLockRewritten { version = 1; };
    in
    assert refuses conflicted && refuses notALock && refuses otherFormat;
    namesCommand "conformance-malformed" (
      problemsOf conflicted ++ problemsOf notALock ++ problemsOf otherFormat
    );

  # Ring at a pinned commit builds from a lockfile kept outside its source:
  # the package of each of its five subprojects, which lein-sub names, and
  # the release with the jar and POM of each.
  example-ring = pkgs.linkFarm "example-ring" (
    lib.mapAttrsToList (name: path: { inherit name path; }) ring.packages
    ++ [
      {
        name = "release";
        path = ring.release;
      }
    ]
  );

  # The test suites of the five Ring subprojects, which run in the sandbox.
  example-ring-tests = ring.tests;

  # The pinned source of Ring, which tests/relock.sh locks again.
  ring-source = pkgs.runCommand "ring-source" { } ''
    cp -r ${ringSource} "$out"
  '';

  # A package written for callPackage takes the builder by name, as any
  # package in an overlay does.
  consumer-package =
    let
      consumerPkgs = withOverlay.extend (
        final: prev: {
          hello-from-lein = final.callPackage (
            { lein-purifier }: (lein-purifier.buildLeinProject { src = ./fixtures/hello; }).packages.hello
          ) { };
        }
      );
    in
    runs "consumer-package" consumerPkgs.hello-from-lein ''{"hello":"world"}'';

  # buildLeinProject.override replaces what the builder takes from the
  # package set: with no JDKs in javaPackages, the build has none to run on
  # and fails evaluation.
  builder-override =
    let
      overridden = withOverlay.lein-purifier.buildLeinProject.override {
        javaPackages = {
          compiler = { };
        };
      };
    in
    assert !(builtins.tryEval (overridden { src = ./fixtures/hello; }).packages.hello.drvPath).success;
    pkgs.runCommand "builder-override" { } "touch $out";

  # lein-purifier.overrideScope replaces what the scope shares: a member
  # that the override adds is in the new scope, and the builder in it is
  # the one of the new scope.
  scope-override =
    let
      scoped = withOverlay.lein-purifier.overrideScope (self: super: { marker = "overridden"; });
    in
    assert scoped.marker == "overridden" && scoped ? buildLeinProject && scoped ? cli;
    runs "scope-override" (scoped.buildLeinProject { src = ./fixtures/hello; }).packages.hello
      ''{"hello":"world"}'';

  # A project whose source holds no lockfile builds from a lockfile kept
  # outside it.
  conformance-external =
    let
      external = build {
        src = builtins.path {
          name = "hello-without-lockfile";
          path = ./fixtures/hello;
          filter = path: _: baseNameOf path != "lein-purifier.lock.json";
        };
        lockFile = helloLockFile;
      };
    in
    runs "conformance-external" external.packages.hello ''{"hello":"world"}'';
}
