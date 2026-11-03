# Ardia dependency inventory for issue #418

Snapshot: Shaar's pinned Ardia commit `91e17a5655519d2dc385ec8452432469232ff9af` (2026-10-22), engine tree `0fd438ac5e7847948832ff6dd080ce9ab0206464`, Chromium `155.0.8059.84`. Sources inspected read-only at `engine-333-364/build/EngineSource/source/ardia` and the synced Chromium tree. This is an inventory of the **current integration**, not a proposal to reuse its implementation. See [[Engine_Shaar_Layer_Design]], [[Engine_Source_Build]], [[Engine_Interop_Boundary]].

## Explicit ABI and Swift routes

Swift imports `ChromiumBridge`, not `ArdiaCore.h` or `ac_engine.h`. The boundary is `ARCChromiumRuntime` in `Sources/ChromiumBridge/include/ChromiumBridge.h`; `Sources/ChromiumBridge/ChromiumRuntimeInternal.h` retains Ardia objects. The table lists every `ac_*` function that Shaar resolves. `ChromiumEngineServices.mm:45-67` resolves the names; `:98-126` sends JSON and filters private events. All service calls require a loaded regular profile path. “Optional” means a missing export fails that particular feature, while the other 15 are startup requirements.

| `ac_*` export | Bridge call site | Swift call site / feature |
| --- | --- | --- |
| `ac_engine_abi_version` | `ChromiumEngineServices.mm:45-57` | `NativeBrowserHost.swift:1136` creates the runtime; ABI 2 is mandatory before `BrowserEngine.swift` uses it. |
| `ac_engine_set_event_sink` | `ChromiumEngineServices.mm:46,74-79,118-126` | `BrowserRuntimeEvents.swift`, `BrowserEngine.swift` feed download and library state; private events are discarded. |
| `ac_downloads_list` | `ChromiumDownloads.mm:25` | `BrowserEngine.swift:610`, `BrowserStore.swift:280,343` restore/refresh Downloads. |
| `ac_downloads_pause` | `ChromiumDownloads.mm:43-63` | `BrowserEngine.swift:251` pause action. |
| `ac_downloads_resume` | same | `BrowserEngine.swift:251` resume action. |
| `ac_downloads_cancel` | same | `BrowserEngine.swift:251` cancel action. |
| `ac_downloads_remove` | same | `BrowserEngine.swift:251` remove from Downloads. |
| `ac_bookmarks_tree` | `ChromiumLibrary.mm:38` | `BrowserEngine.swift:194`, `BrowserLibraryModel.swift` bookmark tree. |
| `ac_bookmarks_apply` | `ChromiumLibrary.mm:65` | `BrowserEngine.swift:223,880`, `BrowserRuntimeEvents.swift:197` bookmark edits. |
| `ac_bookmarks_watch` | `ChromiumLibrary.mm:30-32` | `BrowserLibraryModel.swift` invalidation; apply requires explicit refresh because it suppresses its own event. |
| `ac_history_query` | `ChromiumLibrary.mm:76` | `BrowserEngine.swift:204`, `SettingsServices.swift:27` history and clear-history UI. |
| `ac_history_delete_urls` | `ChromiumLibrary.mm:90` | `BrowserEngine.swift:227`, `BrowserRuntimeEvents.swift:212`, `SettingsServices.swift:39`. |
| `ac_history_watch` | `ChromiumLibrary.mm:30-32` | `BrowserLibraryModel.swift` history invalidation. |
| `ac_site_settings_get` | `ChromiumSiteControls.mm:120`; `ChromiumPrivatePrivacy.mm:68` | `BrowserEngineSiteControls.swift:46`, `ProfilePrivacyModel.swift:38`, `SiteControlsPrivate.swift:35` (private cookie exception with `offTheRecord:true`). |
| `ac_site_settings_set` | `ChromiumSiteControls.mm:138`; `ChromiumPrivatePrivacy.mm:94` | `BrowserEngineSiteControls.swift:61`, `SiteControlsPrivate.swift` regular/private cookie controls. |
| `ac_site_settings_origins` (optional) | `ChromiumSiteControls.mm:32` | `ProfilePrivacyModel.swift:35` exact-origin permission list. |
| `ac_site_settings_reset` (optional) | `ChromiumSiteControls.mm:54` | `ProfilePrivacyModel.swift:42` exception reset. |
| `ac_site_data_clear` | `ChromiumSiteControls.mm:149` | `BrowserEngineSiteControls.swift:78` clear selected origin. |
| `ac_browsing_data_clear` | `ChromiumSiteControls.mm:25,156` | `ProfilePrivacyModel.swift:29`, `BrowserEngineSiteControls.swift` clear profile site data/cache. |

The C types `ac_engine_reply_t`, `ac_engine_call_t`, `ac_engine_event_t`, `ac_engine_abi_version_t`, and `ac_engine_set_event_sink_t`, plus `AC_ENGINE_ABI_VERSION`, are consumed in `ChromiumEngineServices.mm` through `ac_engine.h`; there is no Swift import of them. The local `profile-download-directory.patch` adds `ac_downloads_directory_get` and `ac_downloads_directory_set` to **source builds only**. Neither is resolved or called by the current bridge. `downloadsDirectoryForProfileID:` currently reads the profile directory in the ObjC bridge; the shipped prebuilt engine does not implement the overlay's folder choice.

| Ardia ObjC type / protocol | Bridge files that hold or call it | Swift route / feature |
| --- | --- | --- |
| `ArdiaCoreEngine`, `ArdiaCoreEngineDelegate` | `ChromiumBridge.mm`, `ChromiumPrivateBrowsing.mm`, `ChromiumSiteControls.mm`, `ChromiumRuntimeInternal.h` | `BrowserEngine.swift`, `BrowserRuntimeEvents.swift`, `ProfilePrivacyModel.swift`: run loop, profile load/release/delete, permission and external-app prompts, quit. |
| `ArdiaCoreProfile` | above plus `ChromiumExtensions.mm`, `ChromiumPrivatePrivacy.mm`, `ChromiumSiteControls.mm` | `BrowserEngine.swift`, `PrivateBrowserHost.swift`, `ProfilePrivacyModel.swift`, `ExtensionManagement.swift`: profile ownership, OTR lease, extension list, prefs. |
| `ArdiaCoreWindow`, `ArdiaCoreWindowDelegate` | `ChromiumBridge.mm`, `ChromiumPrivateBrowsing.mm`, `ChromiumDevTools.mm`, `ChromiumRuntimeInternal.h` | `MiniBrowserWindow.swift`, `PrivateBrowserWindow.swift`, `BrowserWindow.swift`: native window/host view, tab strip, popup, close/show requests. |
| `ArdiaCoreTab`, `ArdiaCoreTabDelegate` | `ChromiumBridge.mm`, `ChromiumExtensions.mm`, `ChromiumDevTools.mm`, `ChromiumDeveloperMode.mm`, `ChromiumInspector.mm`, `ChromiumMediaSession.mm`, `ChromiumPictureInPicture.mm`, `ChromiumSiteControls.mm`, `ChromiumPrivatePrivacy.mm`, `ChromiumWebStoreFit.mm`, `ChromiumRuntimeInternal.h` | `BrowserEngine.swift`, `BrowserEngineSiteControls.swift`, `BrowserEngineDevTools.swift`, `BrowserEngineMedia.swift`, `PageFindState.swift`, `DeveloperPageModel.swift`, `InspectorModel.swift`: navigation, views, find, protocol calls, media, extension actions. |

No other `ArdiaCore*` type is referenced by `Sources/ChromiumBridge`. The bridge uses dynamic class lookup for engine/window startup; the ObjC protocols deliver many callbacks that are translated into the Swift runtime callbacks. `ChromiumBridge.mm:788-825` defers tab-strip reconciliation after activation to avoid reentering an Ardia notification. These callback and lifetime rules are part of the migration contract.

## Source layers copied into Chromium

The ordered `engine/patches/series` applies 39 Chromium patches, then copies `engine/chromium/src` and `engine/ardiacore/src`. The following lists cover **all 63 C++/ObjC++ implementation files** in those two source layers (30 + 33); `.h`, `BUILD.gn`, exports, renderer resources, and branding assets accompany them but are not implementation files. Paths in the first column are relative to `engine/chromium/src/chrome/browser/ardia/` or `engine/ardiacore/src/ardia/core/`. All these Ardia-authored files are from the Apache-2.0 pin. A new Shaar layer must be written independently.

| Subsystem and Shaar dependency | `chrome/browser/ardia/` C++/ObjC++ files | `ardia/core/` C++/ObjC++ files |
| --- | --- | --- |
| Process, lifecycle, windows, tabs, navigation, profile isolation and restoration | `ac_cli_control.cc`, `ac_engine.cc`, `ac_memory.cc`, `ac_process.cc`, `ac_tab_restore.cc`, `ac_tabs.cc` | `ac_browser.mm`, `ac_browser_window.mm`, `renderer/ac_content_renderer_client.cc`, `ac_host_visibility.mm`, `ac_lifetime.mm`, `ac_main_delegate.cc`, `ac_navigation_hold.mm`, `ac_seams.mm`, `ac_tab_info.mm`, `ardiacore_api.mm` |
| Downloads and profile-scoped services | `ac_downloads.cc`, `ac_browsing_data.cc`, `ac_cookies.cc`, `ac_site_settings.cc` | `ac_icon_fetch.mm`, `ac_permissions.mm` |
| Bookmarks, history, favicons, search and omnibox | `ac_bookmarks.cc`, `ac_history.cc`, `ac_favicons.cc`, `ac_omnibox.cc`, `ac_search_engines.cc` | `ac_strings.cc` |
| Extensions, actions, page bridge and scripting | `ac_extension_actions.cc`, `ac_extensions.cc`, `ac_extensions_sync.cc`, `ac_scripts_policy.cc` | `ac_extension_shortcuts.mm`, `ac_extension_view.mm`, `ac_installed_bubble.mm`, `ac_page_channel.mm` |
| DevTools, developer diagnostics and security controls | `ac_cli_token_policy.cc`, `ac_reauth.cc`, `ac_sensitive_args.cc` | `ac_devtools_call.mm` |
| Permissions, external apps, dialogs, autofill/password UI | `ac_autofill.cc`, `ac_external_apps.mm`, `ac_passwords.cc` | `ac_autofill_prompt.mm`, `ac_autofill_trigger.mm`, `ac_context_menu.mm`, `ac_desktop_capture.mm`, `ac_device_chooser.mm`, `ac_external_apps.mm`, `ac_modal_dialog_host.mm`, `ac_password_prompt.mm`, `ac_test_system_permissions.mm` |
| Media, PiP, capture, rendering and power behavior | `ac_input_frame_rate.mm`, `ac_zoom.cc`, `pip/ac_pip_controls.cc`, `pip/ac_pip_mac.mm`, `pip/ac_pip_window.cc` | `ac_cast_dialog.mm`, `ac_fake_media.mm`, `ac_picture_in_picture.mm`, `ac_test_media_route_provider.cc`, `ac_video_upscaler.mm`, `ac_video_upscaling.mm` |

The `engine/chromium` layer also installs `chrome/browser/ardia/public/ac_engine.h`, `ac_engine.exports`, `BUILD.gn`, headers and Ardia/Chromium branding resources. The `engine/ardiacore` layer installs public `ArdiaCore.h`, private hook headers and GN/build hooks. Source-build-only overlay: `ThirdParty/ArdiaCore/patches/profile-download-directory.patch` edits `ac_downloads.cc/.h` and `ac_engine.cc/.h` after the series.

## Chromium patches in series order, grouped by dependency

Every name below is from the pinned `engine/patches/series` (39 entries); group order here is thematic, while **the build must retain series order** until replacement. “A” = pinned Ardia Apache-2.0 contribution; “C” = CEF BSD-3-Clause carryover. Chromium files modified by patches retain their own upstream notices and third-party licenses; patch provenance does not relicense Chromium.

| Subsystem / feature relying on behavior | Patches | Provenance |
| --- | --- | --- |
| Embedded Browser and macOS hosting: empty tab strips/private teardown, key conversion, bubbles, print sheets, locale; native host views, tab lifecycle and window presentation | `chromium-cef-carryover.patch`, `chromium-autofill-address-bubble-window.patch`, `chromium-initial-document-access.patch`, `chromium-hidden-window-current-window.patch`, `chromium-window-hosted.patch` | C for CEF carryover; A for remaining patches. |
| App entry/brand and offline page | `chromium-branding.patch`, `chromium-neterror-game.patch`, `chromium-ardia-layer.patch` | A; `chromium-ardia-layer` hooks GN into copied layers. The generated game resource is an additional staged build input. |
| Extensions: installer prompts, updates, policy, component extension access, hidden popup windows, side panel, installed bubble | `chromium-side-panel-hook.patch`, `chromium-extension-install-prompt-hook.patch`, `chromium-extension-updates.patch`, `chromium-extension-omaha-attributes.patch`, `chromium-extension-management-policy-hook.patch`, `chromium-extension-sync-installer-hook.patch`, `chromium-unpacked-load-path-hook.patch`, `chromium-extension-window-hidden.patch`, `chromium-component-extension-restricted-urls.patch`, `chromium-extension-installed-bubble.patch` | A. These support Shaar's extension list/actions, Web Store install consent, popup/side panel ownership and Bitwarden fixture. |
| Component updater and data protection: security components, keychain compatibility, file-type metadata | `chromium-component-updater-security-only.patch`, `chromium-safe-storage-name.patch`, `chromium-safe-browsing-off-file-types.patch` | A. Keychain service/account naming is data compatibility, not a branding choice. |
| DevTools and Inspector: dock/undock, display and title, restricted remote protocol access | `chromium-devtools-redock-display.patch`, `chromium-devtools-window-title.patch`, `chromium-devtools-control-token.patch`, `chromium-window-docked-devtools.patch` | A. Token enforcement and target scoping are security boundaries. |
| Passwords and autofill | `chromium-password-bubble-hook.patch`, `chromium-password-generation-local.patch` | A. Native password prompt and local generation flow. |
| Permissions, device chooser, casting and sharing | `chromium-device-chooser-hook.patch`, `chromium-cast-dialog-hook.patch`, `chromium-tab-sharing-capturer.patch` | A. Prompt ownership, media routing and tab capture. |
| PiP, video rendering and responsiveness | `chromium-pip-overlay-window.patch`, `chromium-video-super-resolution.patch`, `chromium-begin-frame-warm-up.patch`, `chromium-main-frame-throttle-after-show.patch`, `chromium-main-frame-full-rate-on-input.patch`, `chromium-thaw-live-connections.patch`, `chromium-battery-saver-full-rate-on-input.patch` | A. PiP controls, input latency, visibility and media continuity. |
| Background/privacy/security defaults | `chromium-background-features-off.patch`, `chromium-emudhra-distrust.patch` | A; eMudhra patch is a specific certificate distrust, requiring independent current security review on upgrade. |

## Implicit contracts to preserve or decide explicitly

- **CEF carryover:** Browser/private-profile teardown safety, no-active-tab color handling, macOS key conversion, bubble placement, print-sheet resizing/focus, ResourceBundle delegate and background-mode build settings come from the CEF-derived patch. Removing the patch without equivalent behavior can break normal window and private-session lifecycle.
- **Extension window and install path:** Chromium's extension windows are hidden and attached to native Shaar windows. Installation, sync update, unpacked path policy, extension management policy, action popup and side panel hooks support `ChromiumExtensions.mm` and the app's consent UI; do not replace them with arbitrary page JavaScript. Chromium persists installed extensions per profile.
- **DevTools token:** The patch adds token checks at the HTTP handler, agent host and input protocol. `ChromiumDevTools.mm`, `ChromiumDeveloperMode.mm` and `ChromiumInspector.mm` use in-process protocol calls; remote control must stay unavailable without an explicit authorized token and tab scope.
- **Component updater:** Ungoogled defaults alone are not the effective build behavior. The security-only patch narrows update endpoints/payloads; extension update patches separately preserve extension updates. Recheck both network policy and security component freshness before release.
- **Keychain:** `chromium-safe-storage-name.patch` preserves the existing “Ardia Safe Storage” / “Ardia” keychain identity holding encryption keys for cookies/passwords. A Shaar rename needs an explicit key migration and rollback plan; a blind rename loses access to existing data.
- **Find/navigation:** `ArdiaCoreTab.find`, `stopFinding`, navigation entries, initial document access, page channel and tab restore create visible find counts, back/forward, managed tab durability and popup behavior. The adapter's activation callback occurs inside tab-strip notification; defer reconciliation.
- **Private sessions:** Ardia's primary OTR profile is leased from a regular profile; Swift tracks private context/window/tab identities separately. The C service event path is the regular profile path even for private events, so the bridge drops those events. The new layer must attach a distinct private-session ID to every event and reject persistence-sensitive operations for OTR sessions.
- **Downloads and library:** Chromium owns downloads, bookmarks and history. `bookmarks.apply` does not emit its own change event; Swift refreshes after acknowledgement. The current service lacks history insertion needed by #299. Source-build directory overlay is absent from the shipped engine.
- **Media:** PiP window hooks, media capture prompts, tab sharing, casting, frame scheduling and video upscaling are engine-side. `ChromiumMediaSession.mm` also injects a main-world script because the pinned API has no native Media Session surface; migration must preserve playback controls and correct frame ownership.
- **Other pinned behavior:** `ac_scripts_policy.cc` and hooks enforce extension load paths and permissions; `ac_reauth.cc`/sensitive-argument controls and the eMudhra distrust patch require specific security review when replaced. Ardia branding/offline game is not a Shaar product requirement, but its GN/resource effects must be accounted for.

## Build and license boundary

`scripts/fetch-engine.sh` verifies the prebuilt archive SHA-256 from `pin.json`; `scripts/bundle-app.sh` copies the framework and `LICENSE`/`NOTICE`/pin into the bundle. This is today's normal bundle/CI path. `scripts/build-engine-source.py --run` is separate and opt-in: clone pinned Ardia and Chromium, verify tree/commits, stage Ardia build scripts, sync Chromium, apply ungoogled patches and domain substitution, apply the 39 Ardia patches plus both layers, apply Shaar's download overlay, generate GN args, build `chrome_framework`, and record a hash-rich receipt. No build was run for this inventory.

The pinned Ardia files and public headers carry Apache-2.0; the CEF carryover explicitly says BSD-3-Clause. Chromium is BSD-3-Clause **and** many component licenses retained in its `chrome://credits`/resources. Ungoogled Chromium is separately BSD-3-Clause. Shaar's bridge/scripts are MPL-2.0. The pinned `NOTICE` also mentions a separately bundled GPL-3.0 uBlock Origin extension, Sparkle and React Native; Shaar does not fetch Ardia's extension bundle or its React Native adapters. Issue #418 records a later Ardia “as distributed” GPL-3.0 relicense on 2026-10-23, after this pin. No later Ardia code should enter the replacement. Preserve applicable notices and perform release compliance review on the actual new artifact.
