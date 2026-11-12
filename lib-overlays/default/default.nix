# SPDX-License-Identifier: MIT
#
# The `lein-purifier` library namespace, which holds `readLock`. It reads a
# lockfile into the lock in memory of the purifier contract
# (lib-overlays/default/read-lock.nix), and uses the shared library, which this flake
# lists in `projects`, as `lib.purifier`. The builder `buildLeinProject`
# needs a package set, so it is a package that the default package overlay
# adds.
{ ... }:
{

  overlay = final: prev: {
    lein-purifier = (prev.lein-purifier or { }) // {
      readLock = import ./read-lock.nix { lib = final; };
    };
  };

}
