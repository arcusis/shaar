# Automatic picture-in-picture

Merged in [PR #329](https://github.com/arcusis/shaar/pull/329).

When a page with a playing, audible video leaves the screen (another tab, Space or split selection), Shaar asks the page, with a user gesture, to open Chromium's own video picture-in-picture window for its largest playing video; returning to the page closes that window. The request runs before the native selection changes. A window the user opened is left alone. Pages that register `enterpictureinpicture` (video calls) use Chromium's automatic picture-in-picture under its content setting, which the engine allows by default; Shaar does not request a second window for them.

The setting is per site (lowercased http or https host) and per profile, on by default, and stored in preferences. `BrowserStore.automaticPictureInPictureAllowed(for:profileID:)` and `setAutomaticPictureInPicture(_:for:profileID:)` are the shared API for site controls. When a site is off, Shaar does not open the window and the page script withholds the page's `enterpictureinpicture` handler from Chromium, which turns off Chromium's automatic picture-in-picture for that page as well.

Muted, zero-volume, paused and audio-only media do not qualify. The automatic request covers main-frame videos; cross-origin iframe videos and switching to another application are outside its scope. Back to Tab selects the owning tab and Space. Private tabs keep their own activation path.

`AutoPictureInPictureTests` and `SiteSettingKeyTests` cover state and host-key normalization. `MediaSessionProbe` checks tab/Space departure and return, per-site opt-out, and engine PiP events against silent loopback media. The visible per-site toggle lives in [[Site_Control_Center]].

Related: [[Media_Playback]], [[Picture_In_Picture_Controls]], [[Profile_Space_Isolation]].
