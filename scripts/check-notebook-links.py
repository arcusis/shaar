#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Validate local wiki links in the project Notebook."""

from pathlib import Path
import re
import sys


def main():
    root = Path(__file__).resolve().parents[1] / 'Notebook'
    notes = list(root.rglob('*.md'))
    names = {path.stem for path in notes}
    failures = []
    for path in notes:
        for number, line in enumerate(path.read_text().splitlines(), 1):
            for link in re.findall(r'\[\[([^\]]+)\]\]', line):
                target = link.split('|', 1)[0].split('#', 1)[0]
                if target and Path(target).stem not in names:
                    failures.append(f'{path.relative_to(root.parent)}:{number}: missing [[{target}]]')
    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        return 1
    print(f'Notebook links valid ({len(notes)} notes).')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
