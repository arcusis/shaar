# Media playback controls

Chromium's media sessions are not exposed by the pinned engine API, so the bridge installs a main-world page script (`Sources/ChromiumBridge/ChromiumMediaSession.mm`) that runs in every web frame before page code. It records the page's Media Session action handlers, reads metadata and playback state, and posts one report per frame. The bridge treats reports as untrusted: it keeps known keys only, bounds text, accepts only http(s) artwork and known action names, and reduces frames to one state per tab (a playing frame wins, otherwise the latest report). Actions go back to that frame and call the page's own handler; play, pause and seeking fall back to the playing element only where the outcome is certain. Mute uses the engine's tab mute. State resets on each new document, renderer exit and tab close.

The sidebar footer shows a compact player for a tab that has played and is not on screen (neither selected nor in the selected split). A playing tab wins over a paused one, then the most recent start. Paused tabs keep the player so they can resume; a stopped, closed or navigated tab removes it. Previous, play/pause and next appear only for actions the page supports. The site icon and title select the tab, switching Space when needed.

The engine fixture plays a silent canvas stream with an authored Media Session on loopback and checks metadata, supported actions, handler delivery, mute, player visibility and selection. It does not establish compatibility with specific sites such as YouTube Music or Spotify; check those in a local preview build.

Related: [[Media_Consent]], [[Engine_Interop_Boundary]].
