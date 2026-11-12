# SPDX-License-Identifier: MIT
#
# The lein-purifier command, with `lein-purifier lock`, `prefetch` and
# `publish`, and `lein`, the Leiningen of the everyday loop, which is the
# same script run under that name. It calls the `nix` and `nix-store` of
# the Nix installation it runs on.
{
  stdenv,
  lib,
  python3,
  purifier ? lib.purifier,
  runCommand,
  writeShellApplication,
  leiningen,
  jq,
  unzip,
  gnutar,
  coreutils,
  findutils,
  gnused,
  gawk,
}:
let
  # The source of this flake, with its flake.lock. The command evaluates it
  # to build with the same library and nixpkgs as a Nix build does, so it
  # is copied into the store here and the command depends on the copy. A
  # path interpolated without this copy names a store path that a machine
  # evaluating the flake from a git checkout may never create.
  source = builtins.path {
    path = ../..;
    name = "lein-purifier-source";
  };

  script = writeShellApplication {
    name = "lein-purifier";
    runtimeInputs = [
      leiningen
      python3
      jq
      unzip
      gnutar
      coreutils
      findutils
      gnused
      gawk
    ];
    runtimeEnv = {
      LEIN_PURIFIER_FLAKE = "${source}";
      LEIN_PURIFIER_SYSTEM = stdenv.hostPlatform.system;
      LEIN_PURIFIER_FORMAT = toString (import ../../lib-overlays/default/lock-version.nix);
      LEIN_PURIFIER_LEIN_VERSION = leiningen.version;
      LEIN_PURIFIER_INIT = ./init.clj;
      LEIN_PURIFIER_PROJECT_INPUTS_TOOL = "${purifier.projectInputsTool}/project_inputs.py";
      LEIN_PURIFIER_PROJECTION_INIT = ../build-lein-project/project-inputs.clj;
      LEIN_PURIFIER_ENTRIES = ./entries.sh;
    };
    text = builtins.readFile ./lein-purifier.sh;
  };
in
runCommand "lein-purifier"
  {
    meta.mainProgram = "lein-purifier";
    passthru = { inherit script; };
  }
  ''
    mkdir -p $out/bin
    ln -s ${script}/bin/lein-purifier $out/bin/lein-purifier
    ln -s ${script}/bin/lein-purifier $out/bin/lein
  ''
