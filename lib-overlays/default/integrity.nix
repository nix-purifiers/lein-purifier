# SPDX-License-Identifier: MIT
#
# The integrity of a lockfile, given as the attribute set
# builtins.fromJSON reads: the SHA-256, in hex, of every field of it in a
# fixed text form. The lockIntegrity function of the lein-purifier command
# (pkgs/lein-purifier/entries.sh) writes the same text, and the lockfile
# stores its hash as `integrity`, so lock-problem.nix reports a lockfile
# edited by hand.
lock:
let
  join = separator: list: builtins.concatStringsSep separator list;
in
builtins.hashString "sha256" (
  join "" (
    [
      "version\t${toString lock.version}\n"
      "leinVersion\t${lock.leinVersion}\n"
      "javaMajor\t${lock.javaMajor}\n"
      "definitionHash\t${lock.definitionHash}\n"
      "uberjar\t${if lock.uberjar then "true" else "false"}\n"
    ]
    ++ map (
      p:
      "project\t${p.dir}\t${p.group}\t${p.name}\t${p.version}\t${
        if p.mainClass == null then "" else p.mainClass
      }\t${join "," p.outputs}\t${join "," p.dependsOn}\n"
    ) lock.projects
    ++ map (r: "projectRepository\t${r}\n") lock.projectRepositories
    ++ map (
      a:
      if a ? contents then
        "contents\t${a.path}\t${builtins.hashString "sha256" a.contents}\n"
      else
        "file\t${a.path}\t${a.url}\t${join " " a.mirrors}\t${a.hash}\n"
    ) lock.artifacts
  )
)
