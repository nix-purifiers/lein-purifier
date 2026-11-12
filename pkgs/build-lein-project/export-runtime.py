# SPDX-License-Identifier: MIT
"""Pass Leiningen's native classpath to the shared repository exporter."""
import os
from pathlib import Path
import sys

sys.path.insert(0, sys.argv[1])
import coursier_runtime

classpath, workspace, cache, catalog, destination = map(Path, sys.argv[2:])
lines = classpath.read_text().strip().splitlines()
if not lines:
    raise ValueError('Leiningen did not print its native classpath')
paths = []
for entry in lines[-1].split(os.pathsep):
    path = Path(entry)
    # Lein includes optional source/resource directories even when absent.
    # Project classes and resources are published in its own JAR; external
    # unmanaged entries still require an explicit projection.
    if path.is_relative_to(workspace) and not path.is_file():
        continue
    paths.append(entry)
coursier_runtime.export(cache, paths, catalog, destination)
