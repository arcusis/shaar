# Device chooser evidence

Before this change, Web Serial and Web Bluetooth called IOBluetooth on the browser main thread. The page froze the browser, and no chooser appeared. Web USB rejected with "No device selected." and also showed no chooser.

These shots are the sheet after the fix. They were rendered offscreen from the same SwiftUI view the window presents, inside a hidden verification run of `scripts/test-device-choosers.py`. No window was ordered on screen. Serial and Bluetooth were blocked because Bluetooth is not allowed for the responsible process, so those requests did not enter IOBluetooth. The main thread did not stall. Cancel rejected each page with NotFoundError. Connect stays off until a device can actually be granted. The populated USB shot is the same sheet with two example rows so the selection state is visible. The current engine has no device list, so a live page cannot enable Connect yet.

![Serial, Bluetooth unavailable](serial-chooser.png)

![Bluetooth unavailable](bluetooth-chooser.png)

![USB, no devices](usb-chooser.png)

![HID, no devices](hid-chooser.png)

![USB with example devices](usb-populated.png)
