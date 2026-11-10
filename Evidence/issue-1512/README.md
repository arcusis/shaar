# Device chooser evidence

Before this change, Web Serial and Web Bluetooth called IOBluetooth on the browser main thread. The page froze the browser, and no chooser appeared. Web USB rejected with "No device selected." and also showed no chooser.

These shots are the sheet the engine permission event presents. They were rendered offscreen from that SwiftUI view inside a hidden verification run of `scripts/test-device-choosers.py`. No window was ordered on screen. The pinned engine does not send the device-chooser event yet, so the live page calls the real navigator API. Chromium rejects Serial, Bluetooth, and USB with NotFoundError. Web HID resolves with an empty list, which is Chromium's result when no device is selected. Serial and Bluetooth stay off IOBluetooth on the main thread. The main thread did not stall. Connect stays off until that event includes a device. The populated USB shot is the same sheet with two example rows so the selection state is visible.

![Serial, Bluetooth unavailable](serial-chooser.png)

![Bluetooth unavailable](bluetooth-chooser.png)

![USB, no devices](usb-chooser.png)

![HID, no devices](hid-chooser.png)

![USB with example devices](usb-populated.png)
