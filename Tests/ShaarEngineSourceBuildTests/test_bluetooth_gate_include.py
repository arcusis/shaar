# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep the Bluetooth gate declarations visible to the macOS call sites."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0068-shaar-bluetooth-gate.patch"


class BluetoothGateIncludeTests(unittest.TestCase):
    def test_classic_device_imports_gate_before_using_it(self):
        source = PATCH.read_text()
        section = source.split(
            "diff --git a/device/bluetooth/bluetooth_classic_device_mac.mm "
            "b/device/bluetooth/bluetooth_classic_device_mac.mm\n", 1
        )[1].split("diff --git ", 1)[0]
        self.assertIn('+#include "device/bluetooth/shaar_bluetooth_io_gate.h"', section)
        self.assertIn("+  if (!device::ShaarMayCallIOBluetooth())", section)


if __name__ == "__main__":
    unittest.main()
