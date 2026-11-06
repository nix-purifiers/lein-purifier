#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise the actual capture parser; these are parsing cases, not JVM support claims."""
from pathlib import Path
import re
import subprocess
import sys

source = Path(sys.argv[1]).read_text()
function = re.search(r'^javaMajor\(\) \{\n.*?^\}', source, re.M | re.S).group()
cases = {
    '1.6.0-119': '6',
    '1.7.0_352': '7',
    '1.8.0_504': '8',
    '9+181': '9',
    '11.0.29': '11',
    '17.0.17': '17',
    '21.0.12.1+1': '21',
    '25': '25',
    '27-ea': '27',
}
for version, expected in cases.items():
    actual = subprocess.check_output(['bash', '-c', function+'\njavaMajor "$1"', 'java-major', version], text=True).strip()
    assert actual == expected, (version, actual, expected)
print('PASS legacy, modern and prerelease Java major parsing')
