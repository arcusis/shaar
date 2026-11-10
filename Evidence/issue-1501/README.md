# Screen sharing picker

Hidden run of `scripts/test-platform-prompts.py` against
`build/Shaar Verification.app` (shaar.28). The loopback page changed its
title to the old prompt marker and no sheet appeared. A capture request
bound to that tab, origin, and frame presented the picker. Approving
returned the chosen source. Cancelling returned no source. Every window
stayed hidden. No new crash report was written.

The loading frame is the picker before sources arrive. The second frame
lists this tab, a window, and a screen. The current engine does not send
this request until ABI minor 14, so choosing a source still needs that
capture hook before a MediaStream is produced.

![Looking for screens, windows, and tabs](picker-before.png)

![This tab, a window, and a screen](picker-after.png)
