# SPDX-License-Identifier: MIT
#
# Why a lein-purifier lockfile cannot be used, as a message that names the
# command that fixes it, or null when it can be used. readLock reports the
# message among its `problems`.
#
# A lockfile that is not JSON at all fails in builtins.fromJSON, which
# Nix reports as a syntax error. The usual cause, a merge conflict, is
# found before that.
{ lockFile }:
let
  raw = builtins.readFile lockFile;
  name = toString lockFile;
  supportedVersion = import ./lock-version.nix;

  conflicted = builtins.length (builtins.split "\n<<<<<<< " ("\n" + raw)) > 1;
  lock = builtins.fromJSON raw;
  fields = [
    "version"
    "leinVersion"
    "javaMajor"
    "definitionHash"
    "uberjar"
    "projects"
    "projectRepositories"
    "artifacts"
    "integrity"
  ];
in
if conflicted then
  "lein-purifier: ${name} has merge conflict markers in it; run `lein-purifier lock --force` to write it anew."
else if !(builtins.isAttrs lock && builtins.all (field: lock ? ${field}) fields) then
  "lein-purifier: ${name} is not a lein-purifier lockfile; run `lein-purifier lock --force` to write one."
else if lock.version != supportedVersion then
  "lein-purifier: ${name} has lock format version ${toString lock.version}, and this library reads version ${toString supportedVersion}; run `lein-purifier lock --force` with the lein-purifier revision that provides this library."
else if lock.integrity != import ./integrity.nix lock then
  "lein-purifier: ${name} was changed after `lein-purifier lock` wrote it; run `lein-purifier lock --force` to write it anew."
else
  null
