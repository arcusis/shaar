# Cocoa display patch notices

`patches/0008-native-cocoa-display.patch` retains the pinned Ardia Chromium patch that restores native Cocoa compositing when WebContents detaches from a Views WebView. The Shaar layer invokes this Chromium behavior after releasing the hidden BrowserView presentation. The patch was already present in the owned Chromium build; recording it here makes that required behavior explicit for a clean source build.

The patch is Apache-2.0 licensed; retain `cocoa-display-LICENSE` and `cocoa-display-NOTICE`. Chromium files retain their original BSD notices. This carries no Ardia ABI or runtime dependency.
