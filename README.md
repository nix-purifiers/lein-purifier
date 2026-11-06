# lein-purifier

lein-purifier keeps Leiningen's development workflow on locked,
Nix-resolved dependencies. Use the normal build and test commands in your
working tree; building the project itself in the Nix sandbox is an
optional next step.

## Quickstart

From the project root:

```zsh
nix shell 'github:nix-purifiers/lein-purifier'
lein-purifier lock
lein test
lein uberjar
```

Commit the lockfiles that the lock command writes, including the build
tool's own lockfile when it has one. Keep using the project's usual build,
test and editor commands with this setup. Nix provides the locked
dependencies; the development commands above run outside the Nix sandbox.
No project Nix files are needed for this workflow.

Sandboxed builds of the whole project are an optional
[next step](#building-the-project-with-nix).

The shell provides the `lein` wrapper. Use it for the locked
development workflow. With no purifier lockfile, it warns on standard
error and runs the ordinary tool with impure resolution.

For persistent use, add these packages through your usual Nix configuration.


## Development loop

`nix shell github:nix-purifiers/lein-purifier` puts `lein-purifier` and
its `lein` on the `PATH`, as does a development shell with the `cli`
package. Their `lein` is Leiningen itself, which in a project with a
lockfile runs offline on the locked files:

```zsh
lein run
lein test
lein uberjar
```

In a project with subprojects, which lein-sub or lein-monolith names, a
subproject finds a sibling that it depends on in the local repository
only once `lein install` has put it there, as with Leiningen itself. The
lockfile holds no download of the siblings. A run that needs one fails and
names the directory to install:

```zsh
# then app, which depends on core, can resolve it
cd core && lein install
```

`lein sub install` at the root does the same for every subproject, in the
order that `:sub` lists them. Install a dependency's directory first when
`:sub` lists a subproject before a sibling it needs.

When you add or upgrade a dependency in `project.clj`, the next `lein`
stops and asks you to relock:

```zsh
lein-purifier lock
```

`lein-purifier lock` copies the project to a temporary directory and runs
`lein with-profile +test deps` and `lein do jar, uberjar, pom` there, with
an empty local Maven repository and no user profile, as a sandboxed build
has. A Leiningen init file logs every download Maven Resolver completes
with the URL it came from. A lock is current while every `project.clj` and
`profiles.clj` of the build is unchanged and the Leiningen version is the
same, and `lein-purifier lock` leaves a current lockfile alone. `--force`
relocks regardless, `--no-uberjar` leaves the uberjars out of the lock and
the build, and `--lockfile PATH` (or `LEIN_PURIFIER_LOCKFILE`) names a
lockfile elsewhere. A relock of an unchanged project gives the same
lockfile byte for byte. The lock run uses the Leiningen and the JDK of the
lein-purifier package, and ignores `JAVA_HOME`, so a machine with a JDK of
its own, such as a CI runner, locks the same. The lockfile records the JDK
major version only, and the builder runs on nixpkgs' JDK of that version.

Java versions using the older `1.x` notation record their actual major (`8`
for `1.8.0_504`); modern and early-access versions record their leading major.
This parsing does not establish compatibility with those JVMs or change the
JVM selected by the packaged Leiningen. Existing locks are not rewritten. A
lock that previously recorded `javaMajor: "1"` needs an explicit
`lein-purifier lock --force` with the intended packaged JVM; its integrity
prevents fixing the value by hand. The builder still needs an available JDK
for that major, or an explicit `jdk` argument.

Leiningen has no lockfile of its own, so the versions that a version range
or a SNAPSHOT dependency resolves to are recorded only in
`lein-purifier.lock.json`. `lein-purifier lock` keeps them: it gives the
lock run the repository metadata the lockfile recorded, and Maven Resolver
picks the same versions from it. Leiningen has no update command either,
so `lein-purifier update` resolves the version ranges and SNAPSHOT
versions anew against the repositories and relocks:

```zsh
# every version range and SNAPSHOT
lein-purifier update
lein-purifier update org.clojure/data.json  # only this package
```

A dependency with a fixed version stays as it is, and you change it in
`project.clj`.

lein-purifier is a command that starts Leiningen, not a Leiningen plugin.
The lock run has to start Leiningen with an empty home directory and a
local repository seeded from the lockfile, which a plugin that a running
Leiningen loads cannot arrange.

Maven Central limits the requests that come from one address, so the lock
run downloads its files through Google's mirror of it, unless the project
configures `:mirrors` itself. Each file from Maven Central is locked with
its URL there and with the mirror as the fallback.
`LEIN_PURIFIER_CENTRAL_MIRROR` names another mirror, and an empty value
turns it off.

`lein-purifier publish REPOSITORY [NAME...]` builds the `release` with Nix
and deploys each project's jar and POM with `lein deploy`, so nothing is
compiled outside the sandbox. The repository, its credentials and signing
work as they do for `lein deploy`.

## Dependencies from another purified project

Pass a producer's flake package to `lock`:

```zsh
lein-purifier lock \
  --input 'github:owner/library/<rev>#library'
lein-purifier prefetch
```

The producer must export a Maven view through `projections.maven`. Its
catalog selects the supplied modules automatically, including their Nix-derived
versions. Keep ordinary dependency declarations in the project; no version
rewrite table is needed. Repeat `--input` for additional producers.

The lock records the producer's pinned Nix source, rather than listing its
artifacts as downloads. Relocking retains that pin; `update` refreshes it.
Conflicting providers of the same module are rejected.

For a Nix build definition, the corresponding builder argument is
`projectDependencies = [ producer.packages.${system}.library ];`. By default,
the builder reads the inputs recorded in the lock.

Projected repositories use immutable, Nix-derived versions. The purifier's
publish command deploys those coordinates and supplied dependencies, with
POM references rewritten so ordinary Maven consumers can resolve them.

## Building the project with Nix

Once the native development workflow is working, you can also build and
test the whole project in the Nix sandbox. For this step, keep a flake or
another Nix build definition in the project's repository, or maintain an
external packaging repository that points at its sources and lockfiles.
The builder consumes the same lockfiles as the development workflow.

The flake's `overlays.default` adds one attribute to a package set: the
scope `lein-purifier`, which holds `buildLeinProject` and the command.

A project whose authors want a flake can add one that calls the builder
directly. It can live in the project's repository or in another one, and
it gives `nix build` and `nix flake check`:

```nix
{
  inputs.lein-purifier.url =
    "github:nix-purifiers/lein-purifier";
  inputs.nixpkgs.follows = "lein-purifier/nixpkgs";

  outputs =
    { nixpkgs, lein-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ lein-purifier.overlays.default ];
      };
      project = pkgs.lein-purifier.buildLeinProject {
        src = ./.;
      };
    in
    {
      packages.${system}.default =
        project.packages.hello;
      checks.${system}.tests = project.tests;
    };
}
```

The builder's result has:

- `packages.<name>`: a package for each project, named after it, with the
  jar, the uberjar and the POM in `share/java`, and a launcher in `bin` for
  a project with `:main`. A package lists its jars in `artifacts`, such as
  `artifacts."hello-1.0.0-standalone.jar"`, which are known from the
  lockfile before the build runs.
- `tests`: `lein test` of every project, in the sandbox.
- `release`: the jar and the POM of every project in Maven repository
  layout, which `lein-purifier publish` deploys.
- `fetches`: the entries of the lockfile, for SBOM, license and
  vulnerability tools.

`lein-purifier.lib.lein-purifier.readLock { src, lockFile ? ... }` reads
the lockfile into the shape every purifier shares: `purifier`, the
download `entries`, the `outputs` of each project (its directory, group,
version, main class, jars and the projects of the build it depends on)
and the `problems` that stop a build, each naming the command to run. The
builder reads the lockfile through it.

The builder takes `src` and these arguments:

- `fetchers`, passed to the shared library's `fetchEntry`, such as a
  `fetchurl` with credentials or a company mirror;
- `lockFile` is optional. By default the builder reads the
  `lein-purifier.lock.json` that you commit to the repository, and you pass
  `lockFile` to keep the lockfile elsewhere, as for a project you package
  but do not change;
- `jdk`, whose default is the headless JDK of the major version the lock
  was made with;
- `srcFilter`.

`buildLeinProject` takes what it needs by name (`stdenvNoCC`,
`javaPackages`, `leiningen` and the others), so
`lein-purifier.buildLeinProject.override` replaces any of them, and
`lein-purifier.overrideScope` replaces what the scope shares. We
recommend following the nixpkgs input of lein-purifier, as above: the
builder uses the Leiningen of the package set, and it refuses a lockfile
made with another Leiningen version, because each version adds its own
nREPL dependencies to every project.

### One-off builds without a project Nix file

For an ad hoc build, the builder can also be evaluated directly from the
project root. Replace the example package name with one from your project:

```zsh
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/lein-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.lein-purifier.buildLeinProject { src = ./.; })
.packages.hello'
```

This uses the purifier's pinned nixpkgs, matching the lock command above.
To build with ambient `<nixpkgs>` from your Nix search path instead,
replace `import purifier.inputs.nixpkgs` with `import <nixpkgs>`.
Both forms need no Nix files in your project. The build tool and language
versions must match the lockfile; with ambient nixpkgs, lock with the
purifier from that package set or pass a compatible toolchain to the builder.

## Working offline

```zsh
lein-purifier prefetch
```

fetches every locked file into the Nix store and lays them out as the
local Maven repository in `.lein-purifier/` at the project root, with GC
roots there for the files and for lein-purifier with its Leiningen and
JDK. `lein` prefetches by itself when the lockfile changed, and after
that, the development loop and the editor need no network. Add
`.lein-purifier/` to `.gitignore`.

## Editor

clojure-lsp works with no configuration. It finds the classpath with
`lein with-profile +test,+dev classpath`, and with lein-purifier's `lein`
on the `PATH` of the editor, that runs offline on the prefetched files.
Every dependency of the `dev` and `test` profiles is locked, so the
editor sees the same jars as the build. Start the editor from the shell
that has lein-purifier, or from a development shell with the `cli`
package.

## Troubleshooting

| Message | Cause | Fix |
| --- | --- | --- |
| project.clj or profiles.clj changed, or Leiningen did, after … was made | A dependency, a profile or the Leiningen version changed since the lock | `lein-purifier lock` |
| Leiningen needs an artifact that … does not hold | A task or profile the lock run did not use needs a file | `lein-purifier lock --force` |
| … is a project of this build, so … holds no download of it | A subproject needs a sibling that is not installed yet | `lein install` in the directory the message names |
| … was changed after lein-purifier lock wrote it | The lockfile was edited by hand | `lein-purifier lock --force` |
| … has merge conflict markers in it, or … is not valid JSON | A merge left the lockfile broken | `lein-purifier lock --force` |
| … has lock format version … | The lockfile is from another lein-purifier | `lein-purifier lock --force` |
| Checksum validation failed, no checksums available | An HTTP proxy that needs Basic authentication, which the JVM refuses by default | Run the lock with `LEIN_JVM_OPTS='-Djdk.http.auth.tunneling.disabledSchemes= -Djdk.http.auth.proxying.disabledSchemes='` |

Nix reports the same messages at evaluation, so a broken lockfile fails
before anything builds. `LEIN_PURIFIER=0 lein` runs Leiningen as itself,
and `LEIN_PURIFIER_TRACE=1` prints each command lein-purifier runs.

## Supported language repositories

Supported:

- Dependencies and plugins from any Maven repository, Maven Central and
  Clojars included, and from mirrors that `project.clj` or `profiles.clj`
  configures.
- The dependencies of the `test`, `dev` and `uberjar` profiles, and the
  nREPL dependencies Leiningen adds to every project.
- Version ranges and SNAPSHOT versions. Maven Resolver picks those from
  repository metadata, whose content changes over time at its URL, so the
  lock writes the metadata with the versions the lock run downloaded, and
  the timestamped SNAPSHOT files are ordinary downloads. The build resolves
  to the same versions the lock run did.
- Repositories inside the project, such as `:repositories [["local"
  "file:repository"]]`. Their files are not downloads; the build takes them
  from the project source.
- Projects with subprojects, which lein-sub names in `:sub` and
  lein-monolith in its `:project-dirs`. The lock runs each subproject in
  dependency order and installs it into the local repository, and Nix
  builds one package per subproject, with the packages of the subprojects
  it depends on in its local repository.

Limits:

- **Git dependencies and URL tarballs.** Leiningen resolves dependencies
  from Maven repositories only. Git dependencies exist only through
  third-party plugins such as lein-git-down, which fetch with code of their
  own, outside Maven Resolver, so the lock run cannot see those downloads.
- **`file:` repositories outside the project.** Such a repository is a path
  on one machine, which the sandbox cannot read, so the lock run stops when
  a project uses one.
- **Checkouts.** Leiningen checkouts are links from `checkouts/` to other
  projects on the same machine, so the lock run and the sandboxed build
  leave them out. The development loop keeps them, since it runs in the
  project itself.
- **The user profile in the lock and the build.** The lock run and the
  sandboxed build ignore `~/.lein/profiles.clj`, so a project that needs
  something from it declares it in `project.clj` or `profiles.clj`. The
  development loop keeps the user profile.

Leiningen selects the same artifacts on every platform, so one lockfile
serves x86_64-linux and aarch64-linux. A dependency whose POM activates a
profile by operating system or architecture is the exception: the lock
holds what the platform of the lock run resolved.

## Examples

For day-to-day work on these projects, use the native-tool setup and
commands in [Quickstart](#quickstart) and [Development loop](#development-loop).
The Nix expressions below show optional sandboxed packaging of those
projects.

### Ring

[Ring](https://github.com/ring-clojure/ring) is the web application
library of the Clojure ecosystem. It is a lein-sub project with a
subproject for each part of the library. Say you work on a fork of it.

Lock the fork from its root, and commit the lockfile to the repository
with a flake that builds the project:

```zsh
nix shell 'github:nix-purifiers/lein-purifier'
git clone https://github.com/ring-clojure/ring
cd ring
lein-purifier lock
```

```zsh
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/lein-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.lein-purifier.buildLeinProject { src = ./.; })
.packages.ring-core'
```

This builds one subproject, `ring-core`. Each subproject is a package with
its jar and POM in `share/java`, and the `release` attribute of the
builder's result holds them all in Maven repository layout. The `tests`
attribute runs the tests of all of them in the sandbox.

To work on Ring, run Leiningen from a shell that has lein-purifier, in the
checkout:

```zsh
nix shell github:nix-purifiers/lein-purifier
lein-purifier prefetch
lein test
```

A subproject finds a sibling it depends on only after `lein install` in
the sibling's directory, as the Development loop section describes. Ring
lists `ring-jetty-adapter` before `ring-jakarta-servlet`, which it needs,
so install `ring-jakarta-servlet` first.

To package Ring from another repository without changing Ring, keep the
lockfile in that repository. Lock with
`lein-purifier lock --lockfile ../ring.lock.json`, take Ring as a flake
input that is not a flake (`inputs.ring = { url = "github:ring-clojure/ring";
flake = false; }`), and pass both to the builder in that repository's
flake:
`pkgs.lein-purifier.buildLeinProject { src = ring; lockFile = ./ring.lock.json; }`.


## Credits

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).

Released under the MIT license; see [LICENSE](LICENSE).
