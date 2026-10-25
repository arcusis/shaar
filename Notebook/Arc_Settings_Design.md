# Native Arc-style Settings

Primary visual reference: five user-supplied Arc macOS Settings screenshots. They establish a separate native window with title/traffic lights, icon-and-label toolbar categories, muted grouped rows and restrained selection. Profiles has a left profile list with Space counts and a right settings pane. Links groups Little Arc and Peek options. Personal account details in screenshots are not repository assets.

Use Arc's navigation structure and density, adapted to real implemented browser capabilities. Main settings and controls stay SwiftUI/AppKit. Initial emphasis: General, Profiles, Links and Shortcuts; password-manager controls belong to the selected Profile's passwords/autofill settings. Account/sync, Max, icon and advanced features require their own implemented behavior before controls appear.

Profile owns browser/account data and preferences; Space owns tab organization/theme and references a Profile. Deliberately shared-profile Spaces share those preferences. Switching the selected profile in Settings must never navigate or change another browser window's account.

Requested password-manager UX: enable/disable, provider selection, connect/disconnect and clear connection/lock status. Bitwarden first; show only providers backed by an implemented route. Disabling integration must leave normal browsing usable. Backend choice remains [[Native_Password_Manager_Options]].

Implemented slice: reusable native Settings window, exact Command-Comma, General/Profiles/Shortcuts categories, profile names and unique Space counts. General controls sidebar visibility for new windows; Profiles chooses Google, DuckDuckGo or Bing for that Profile's launcher searches. Shortcuts lists existing commands. Preferences persist separately from account/session data; malformed or future-version files remain preserved. Settings selection never switches a browser window's account. Command-W and Shift-Command-W close Settings when it owns focus.

Profiles supports Add Profile and Rename through a native name-editor sheet. A new profile has its own UUID and zero Spaces until chosen in New Space. Rename changes display metadata, preserving profile-bound preferences and live website accounts. Empty names and stale IDs are rejected; duplicate names remain separate UUID identities. Cancel leaves the workspace untouched. Workspace save failures retain valid in-memory state and show the existing storage notice.

Work order:

1. Verify physical keyboard/focus and accessibility for the implemented window and preferences.
2. Add optional password-manager connection state after a supported backend is established.
3. Add further supported Profile preferences with real behavior and ownership tests.
4. Links routing, editable shortcuts and other settings in bounded follow-ups.
5. Compare normal/compact layouts, focus, hover, transitions and Reduce Motion behavior against supplied/reference material.

Screenshots establish static layout, not animation duration/easing or physical input quality. Official videos/GIFs can supply motion references; exact parity requires measurement and runtime review. Current UI is not accepted as complete or perfected.

Tracking: [Settings #51](https://github.com/arcusis/browser/issues/51), [Arc UI #5](https://github.com/arcusis/browser/issues/5), [existing chrome corrections #24](https://github.com/arcusis/browser/issues/24).

Related: [[Profile_Space_Isolation]], [[Native_Password_Manager_Options]], [[Arc_Reference_Library]], [[Project_State]].
