# SPDX-License-Identifier: MIT
"""Merge native Leiningen module classpaths without choosing conflicting versions."""
import json
from pathlib import Path
import sys

sys.path.insert(0, sys.argv[1])
import jvm_repository as jvm

destination = Path(sys.argv[2])
modules = {}
for source in map(Path, sys.argv[3:]):
    graph = json.loads((source / 'purifier-runtime-modules.json').read_text())
    for module in graph['modules']:
        key = module['group'], module['name']
        previous = modules.setdefault(key, module)
        if previous != module:
            raise ValueError('conflicting selected Leiningen runtime versions: ' + str(key))
    for path in sorted(source.rglob('*')):
        if path.is_file() and path.name != 'purifier-runtime-modules.json':
            jvm.write(destination / path.relative_to(source), path.read_bytes())
jvm.write(destination / 'purifier-runtime-modules.json',
          (json.dumps({'modules': [modules[key] for key in sorted(modules)]}, sort_keys=True) + '\n').encode())
