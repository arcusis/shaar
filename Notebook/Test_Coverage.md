# Test coverage

The coverage tables below are a historical snapshot measured with Swift 6.4.2 (Apple LLVM 21) on macOS 27 against `production` at `192491b` plus the tests added for issue #252. They are not current coverage percentages or line counts. The feature-to-test map is maintained separately against current source.

## Reproduce

```sh
swift test --enable-code-coverage
xcrun llvm-cov report \
  -instr-profile .build/debug/codecov/default.profdata \
  .build/debug/BrowserAppTests.xctest/Contents/MacOS/BrowserAppTests \
  -object .build/debug/BrowserCoreTests.xctest/Contents/MacOS/BrowserCoreTests \
  -ignore-filename-regex='(\.build|Tests|ThirdParty)/'
```

Use `xcrun llvm-cov export -summary-only` with the same arguments for JSON. Both test bundles must be passed, or BrowserCore lines exercised only by `BrowserCoreTests` count as missed.

## Line coverage by module

| Module | Lines | Covered | Before #252 |
| --- | ---: | ---: | ---: |
| BrowserCore | 3,554 | 98.11% | 95.27% |
| ArcusisBrowser, without probes | 22,590 | 51.08% | 50.49% |
| ArcusisBrowser, including probes | 34,664 | 33.29% | 32.90% |
| ChromiumBridge | 3,745 | 2.51% | 2.51% |
| All Swift and Objective-C++ sources | 41,963 | 36.03% | 35.47% |

In that measurement, "probes" were the `*Probe.swift` files and `ChromiumProbeTLS.mm` (12,152 lines), excluded from the "without probes" row. Probes now live in the separate `ShaarVerification` target; its test-only bridge API lives in `ChromiumBridge.Verification`. Future coverage reports must account for this target split rather than reuse the old subtraction. See [[Verification_Harness]].

ChromiumBridge and the engine-facing parts of ArcusisBrowser (`BrowserEngine`, `NativeBrowserHost`, `BrowserRuntimeEvents`, `PrivateBrowserHost`) need a loaded Chromium runtime. Their behaviour is verified by the native engine fixture (see [[Source_And_Native_Verification]]), not by line coverage. SwiftUI view bodies are partly covered by offscreen layout tests. Some capture suites require GitHub Actions macOS CI with `ARCUSIS_SIDEBAR_VISUAL_CI=1`; others, including media player and PiP control tests, render offscreen locally. A skipped capture is not local visual proof.

Files raised by the #252 tests:

| File | Before | After |
| --- | ---: | ---: |
| `BrowserCore/BrowserDownload.swift` | 95.8% | 100.0% |
| `BrowserCore/BrowserExtension.swift` | 83.7% | 100.0% |
| `BrowserCore/BrowserLibrary.swift` | 98.1% | 99.1% |
| `BrowserCore/BrowserSession.swift` | 95.2% | 98.6% |
| `BrowserCore/BrowserSpaceSymbol.swift` | 87.5% | 100.0% |
| `BrowserCore/BrowserSplitLayout.swift` | 86.9% | 98.9% |
| `BrowserCore/BrowserWorkspace.swift` | 96.6% | 98.4% |
| `BrowserCore/CommandSearch.swift` | 95.6% | 97.6% |
| `BrowserCore/SessionFolders.swift` | 88.4% | 100.0% |
| `BrowserCore/WorkspaceProcessLock.swift` | 62.5% | 84.4% |
| `ArcusisBrowser/BookmarkEditorRoute.swift` | 68.2% | 81.8% |
| `ArcusisBrowser/BrowserPreferencesStore.swift` | 88.0% | 89.4% |
| `ArcusisBrowser/BrowserStoreLibrary.swift` | 64.4% | 98.9% |
| `ArcusisBrowser/DownloadsModel.swift` | 95.2% | 100.0% |
| `ArcusisBrowser/ExtensionManagement.swift` | 89.0% | 91.5% |
| `ArcusisBrowser/ExtensionManagerModel.swift` | 14.5% | 16.2% |
| `ArcusisBrowser/LibraryDownloadQuery.swift` | 87.3% | 98.0% |
| `ArcusisBrowser/PrivateBrowserStore.swift` | 65.8% | 98.7% |
| `ArcusisBrowser/ProfileAccounts.swift` | 79.1% | 97.7% |
| `ArcusisBrowser/SplitDropZone.swift` | 9.8% | 10.7% |

## Feature to test map

App tests live in `Tests/BrowserAppTests`, core tests in `Tests/BrowserCoreTests`, harness tests in `Tests/ShaarVerificationTests`, and tooling/release/packaging tests in the Python suites under `Tests/`. Native probes run inside the engine fixture. Pending site-control tests are described in [[Site_Control_Center]]; they are not part of this branch's map.

| Feature | Unit tests | Native probe |
| --- | --- | --- |
| Profiles and Spaces, shared profiles, profile reassignment | `WorkspaceProfileTests`, `SpaceProfileReassignmentTests`, `SpaceProfileStoreTests`, `SessionLifecycleTests`, `BrowserSettingsProfileTests`, `SettingsProfilesPaneTests` | `WorkspaceProbe`, `NativeHostProbe` |
| Space and profile editors: name, symbol, colour, theme | `SpaceColorTests`, `HSBColorTests`, `SpaceColorEditorTests`, `SpaceChromeTintTests`, `SymbolCatalogTests`, `ThemeColorPickerModelTests`, `SpaceEditorVisualTests`, `SpaceIconPickerVisualTests`, `ProfileEditorVisualTests` | — |
| Switching Spaces: pager, shortcuts, swipe | `SpacePagerTests`, `SpaceShortcutTests`, `SpaceSwipeNavigationTests`, `SpaceScaleTests` | — |
| Sidebar tabs: pin, order, drag and drop, visibility | `SessionOrderingTests`, `SidebarOrganizationTests`, `SidebarTabIndexTests`, `SidebarDropTests`, `SidebarTransferTests`, `SidebarVisibilityTests`, `SidebarChromeLayoutTests` | `OrderingProbe` |
| Sidebar folders | `SessionFolderTests`, `FolderStoreTests`, `SidebarFoldersVisualTests` | `FolderProbe` |
| Tidy tabs | `SidebarTidyTests` (site grouping fallback) | — |
| Favorites | `BrowserFavoritesTests`, `WorkspaceFavoritesTests`, `WorkspaceCatalogTests`, `FavoriteCommandSearchTests`, `FavoriteConsentMatchingTests`, `FavoriteCommandActionTests`, `FavoriteSelectedPageTests`, `FavoriteStoreLifecycleTests`, `FavoriteWorkspaceStoreTests`, `ProfileFavoritesGridTests`, `SidebarFavoritesLayoutTests` | `NativeFavoritesProbe` |
| Split view | `SessionSplitTests`, `SplitLayoutPresetTests`, `BrowserSplitStoreTests`, `SplitPageVisualTests` | — |
| Command launcher and filters | `CommandLauncherTests`, `CommandSearchScaleTests`, `CommandSearchLimitTests`, `CommandLauncherStoreTests`, `CommandPanelSurfaceTests`, `CommandPanelVisualTests` | — |
| Address input and search engines | `SearchEngineTests`, `BrowserPreferencesTests` | `NativeHostProbe` |
| Copy clean link | `CleanLinkTests` | — |
| Windows: placement, geometry, tab selection, drag region | `BrowserWorkspaceTests`, `BrowserWorkspaceStoreTests`, `NativeWindowPlacementTests`, `NativeTabSelectionTests`, `WindowDragRegionTests`, `ChromiumPageContainerHandoffTests` | `NativeWindowProbe`, `WindowClientProbe`, `NativeSelectionProbe` |
| Page chrome and layout | `BrowserChromeLayoutTests`, `PageChromeLayoutTests`, `ChromiumPageLayoutTests`, `PageResizeLayoutTests`, `TabMaterializationPolicyTests` | `NativeHostProbe` |
| Mini browser window | `MiniBrowserTests` | — |
| Private window | `PrivateBrowserStoreTests`, `PrivateBrowserHostTests`, `test_private_window_fixture.py` | `PrivateWindowProbe`, `PrivateProductHostProbe` |
| Tab switcher and recency | `TabRecencyTests` | — |
| Recently closed tabs | `ClosedTabTests`, `ClosedTabStoreTests` | `ReopenProbe` |
| Workspace persistence and restart recovery | `BrowserCoreTests`, `SnapshotFileTests`, `WorkspaceProcessLockTests`, `SnapshotSaveSchedulerTests`, `BrowserWorkspaceStoreTests`, `AbruptCheckpointTests`, `SavedTabCapacityTests` | `WorkspaceProbe`, `SavedTabCapacityProbe`, `SessionRecoveryProbe`, abrupt restart run |
| Quit exit and background mode | `BackgroundModeLocalStateTests`, `QuitExitRunnerTests` | `QuitExitProbe` |
| Find in page | `PageFindTests` | `PageFindProbe` |
| Renderer crash recovery | `RendererRecoveryTests` | `RendererRecoveryProbe` |
| Bookmarks and history | `BrowserLibraryTests` (core and app) | `LibraryProbe` |
| Library drawer and Spaces overview | `LibraryDrawerTests`, `LibrarySpacesOverviewTests` | — |
| Downloads: panel, library, recent popover | `BrowserDownloadTests`, `DownloadsTests`, `LibraryDownloadTests`, `RecentDownloadsTests`, `RecentDownloadsInteractionTests`, `BrowserEngineDownloadOpenTests` | `DownloadProbe` |
| Extensions: install consent, management, toolbar pins, Web Store | `BrowserExtensionTests`, `ExtensionConsentTests`, `ExtensionManagementTests`, `ProfileExtensionsSectionTests`, `ExtensionManagerVisualTests`, `WebStoreFitTests` | `ExtensionProbe` |
| Password manager extensions | — | `BitwardenProbe` |
| Camera, microphone and screen consent | `WebsitePermissionRequestTests`, `WebsitePermissionConsentTests` | `MediaPermissionProbe` |
| Media Session bridge and sidebar mini player | `MediaPlaybackModelTests`, `SidebarMediaPlayerVisualTests` | `MediaSessionProbe` |
| Automatic picture-in-picture and controls | `AutoPictureInPictureTests`, `SiteSettingKeyTests`, `PictureInPictureControlsTests` | `MediaSessionProbe` |
| External app links | `ExternalAppRequestTests`, `ExternalAppConsentTests`, `ExternalAppConsentLayoutTests`, `ExternalAppRoutingTests`, `ExternalAppProbeConfigurationTests` | `ExternalAppConsentProbe` |
| Profile accounts (Google, Microsoft) | `ProfileAccountsTests`, `ProfileAccountParsingTests` | — |
| Settings window | `BrowserSettingsIntegrationTests`, `BrowserSettingsLayoutTests`, `SettingsVisualTests` | `NativeHostProbe` |
| Keyboard shortcuts and menus | `ShortcutCatalogTests`, `ShortcutCoverageTests`, `ShortcutVisualTests`, `BrowserShortcutTests`, `NativeMenuStructureTests` | `NativeHostProbe` |
| Engine event routing and probe harness | `BrowserRuntimeRouterTests`, `SwitchProbeMetricsTests`, `ProbeTLSConfigurationTests` | `EngineProbe`, `EngineTLSProbe` |
| Automatic updates | `UpdateFeedTests`, `test_release_feed.py`, `test_release_script.py` | — |
| App bundle, engine payload and resources | `test_bundle_app.py`, `test_verify_engine_bundle.py`, `test_engine_payload.py`, `test_fetch_engine.py`, `test_engine_source_build.py`, `test_browser_resources.py`, `test_engine_fixture.py` | — |
| Notebook index membership | `test_notebook_links.py` | — |

## Known gaps

These features have model or engine coverage but no unit test of the code listed:

- Copy URL menu command (`SpaceCommands.swift`). The cleaning it applies is covered by `CleanLinkTests`; the menu wiring and pasteboard write are not.
- Active capture indicator (`MediaCaptureIndicator.swift`). Consent is covered; the indicator menu is a view over engine state.
- macOS privacy permission status in Settings (`MacPermissions.swift`). It reads system TCC state, which a unit test cannot set.
- Tidy tabs with the on-device language model (`SidebarTidy.swift`). Only the site-grouping fallback runs in tests, because the model is not available on every test machine.
- Account sign-in flow (`ProfileAccountSignIn.swift`) and extension list refresh (`ExtensionManagerModel.refresh`). Both call the engine; their parsing and state rules are covered.
- Sparkle wiring (`AppUpdater.swift`). Feed generation and release checks are covered by the release tests.
- Password manager extensions have only the opt-in `BitwardenProbe`.
- Hosted-only visual capture suites skip outside GitHub Actions macOS CI. Local offscreen captures from other suites do not establish those skipped layouts or physical interaction.

Related: [[Source_And_Native_Verification]], [[Project_State]].
