# Media capture indicator: hidden shipping-bundle proof

Both captures come from the offscreen Shaar shipping app while a localhost page held one fake audio track and one fake video track after website consent. No window was ordered or focused.

- `before-shaar22.png`: shaar.22, with the bridge change in place but no native capture event. The tracks were live, `mediaAccess` stayed inactive, and the toolbar had no In use badge.
- `after-shaar23.png`: shaar.23 with patch 0050. The live capture event reached `mediaAccess`, and the red In use badge appeared at the top right. Stopping both tracks cleared the state.

The smoke checks the badge in the captured top toolbar, where the before image has no red pixels and the after image has the red icon and text. It also checks the app model and the track stop transition.

The shaar.23 run passed both media rows, exited 0, and created no crash report. The full DevTools walk had two unrelated failures: the CSS overview panel root and Elements DOM drag.
