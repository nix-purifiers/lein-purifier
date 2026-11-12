# SPDX-License-Identifier: MIT
#
# readLock: the lock in memory of the purifier contract. The flake's
# library holds it as `lib.lein-purifier.readLock`, and buildLeinProject
# reads the lock through it:
#
#   {
#     purifier = "lein-purifier";
#     entries  = [ <download entry> ];  # every system needs every entry
#     outputs  = { <project name> = { dir, group, version, mainClass,
#                                     files, dependsOn }; };
#     problems = [ <string> ];          # each naming the command to run
#   }
#
# Leiningen has no lockfile of its own, so everything comes from
# lein-purifier.lock.json. Leiningen selects the same artifacts on every
# platform, so no entry carries `systems`. `files` are the jars of a
# project, as paths relative to its directory. A problem stops the build
# when buildLeinProject passes the lock to the shared library's checkLock.
{ lib }:
{
  # The project root, which holds project.clj.
  src,
  # The lockfile. The default is the one `lein-purifier lock` writes at the
  # project root.
  lockFile ? src + "/lein-purifier.lock.json",
}:
let
  lockProblem = import ./lock-problem.nix { inherit lockFile; };
  lock = builtins.fromJSON (builtins.readFile lockFile);
  projectProblem = import ./project-problem.nix {
    inherit
      lib
      src
      lockFile
      lock
      ;
  };
  problem = if lockProblem != null then lockProblem else projectProblem;
in
if lockProblem != null then
  {
    purifier = "lein-purifier";
    entries = [ ];
    outputs = { };
    problems = [ lockProblem ];
  }
else
  {
    purifier = "lein-purifier";
    entries = lock.artifacts;
    outputs = builtins.listToAttrs (
      map (project: {
        inherit (project) name;
        value = {
          inherit (project)
            dir
            group
            version
            mainClass
            dependsOn
            ;
          files = project.outputs;
        };
      }) lock.projects
    );
    problems = lib.optional (problem != null) problem;
  }
