# SPDX-License-Identifier: MIT
#
# The members of the `lein-purifier` scope in the package set. The scope
# comes from the default package overlay (pkg-overlays/default), which
# makes it with lib.makeScope, so everything here is a package for the
# `callPackage` of that scope. `lib` is the library of this flake, which
# holds the shared purifier library.
{ callPackage, lib, ... }:
{
  # The lein-purifier command, with the Leiningen of this package set.
  cli = callPackage ./lein-purifier { };

  # The builder of the purifier contract (pkgs/build-lein-project/default.nix).
  # It takes the packages it needs by name, so `buildLeinProject.override`
  # replaces any of them, and `lein-purifier.overrideScope` replaces what
  # the scope shares.
  buildLeinProject = callPackage ./build-lein-project {
    purifier = lib.purifier;
  };
}
