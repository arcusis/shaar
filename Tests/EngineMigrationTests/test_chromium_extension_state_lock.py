# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ChromiumExtensionStateLockTests(unittest.TestCase):
    def test_shared_runtime_state_map_is_locked_for_lookup_and_insert(self):
        source = (ROOT / "Sources/ChromiumBridge/ChromiumExtensions.mm").read_text()
        start = source.index("static ARCShaarExtensionState *ShaarExtensionState(")
        end = source.index("\n}\n", start)
        accessor = source[start:end]

        lock = accessor.index("[statesLock lock]")
        lookup = accessor.index("[states objectForKey:runtime]")
        insert = accessor.index("[states setObject:state forKey:runtime]")
        unlock = accessor.index("[statesLock unlock]")
        self.assertLess(lock, lookup)
        self.assertLess(lookup, insert)
        self.assertLess(insert, unlock)


if __name__ == "__main__":
    unittest.main()
