# Branded DMG layout

Create a disk image from an existing `Shaar.app` bundle without Finder or desktop interaction:

```sh
scripts/create-branded-dmg.sh build/Shaar.app build/Shaar.dmg
```

The script uses `hdiutil` and `SetFile`, stages the app and an Applications link, applies the checked-in Finder layout and background, and adds the Shaar volume icon. It refuses to replace an existing output file. It does not sign, notarize, or publish the image.

To regenerate the two checked-in layout assets:

```sh
swift scripts/generate-dmg-background.swift Resources/Installer/background.png
python3 -m pip install 'ds_store==1.3.1' 'mac_alias==2.2.2'
python3 scripts/generate-dmg-layout.py
```

The background uses the Shaar palette. The Finder layout pins the app and Applications icons on either side of the arrow in a 660 × 420 window. Both generators are headless.
