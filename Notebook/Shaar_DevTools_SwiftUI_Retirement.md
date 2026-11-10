# Retiring the SwiftUI DevTools panels

Delete one SwiftUI group per pull request, and only after a hidden check on the shipping bundle shows the Chromium dock, or a panel added through [[Shaar_DevTools_Frontend_Panel]], doing that group's job. [[Shaar_Inspector]] stays, including `Sources/ShaarVerification/Inspector*Probe.swift`.

Port these before deleting them: `ShaarViewports*`, `ShaarRepro*`, `ShaarFramework*`, `ShaarNetworkRules*`, and the agent bridge. `ShaarDevToolsNativeTransport.swift` stays while those callers use it. `DevToolsNetworkRulesProof.swift` stays with network rules.

Stock Chromium covers the rest. Order:

1. Console and Network sections in `ShaarDevToolsModel.swift` and `ShaarDevToolsPanel.swift`.
2. Application section, and `Sources/ShaarVerification/ApplicationStorageProof.swift`.
3. Sources section and `ShaarInspectorSourceLoader.swift`, with `DevToolsSourceBytesProof.swift`. Inspector source actions stay.
4. Performance section.
5. Memory section.
6. `ShaarDevToolsCoverage.swift`.
7. Elements: `ShaarDOMTreePanel.swift`, `ShaarDOMTreeModel.swift`, `ShaarDOMLiveTransport.swift`, `ShaarDOMLocator.swift`, `ShaarDOMDrop.swift`, and `DevToolsDOMScaleProof.swift`.
8. Remaining stock panels: `ShaarDevToolsIssues.swift`, `ShaarDevToolsSecurity.swift`, `ShaarDevToolsSensors.swift`, `ShaarDevToolsCSSOverview.swift`, `ShaarDevToolsRecorder.swift`, `ShaarDevToolsAudits.swift`, plus the Rendering and Comparison sections. Split this step when the diff stops being one group.
9. Shell last: `ShaarDevToolsModel.swift`, `ShaarDevToolsPanel.swift`, `ShaarDevToolsFloatingWindow.swift`, `ShaarDevToolsSplitHandle.swift`, `ShaarDevToolsCommandMenu.swift`, `ShaarDevToolsCommands.swift`, `ShaarDevToolsSettings.swift`, `ShaarDevToolsListProjection.swift`, `ShaarDevToolsSmoke.swift`, `ShaarDevToolsSmokeExercise.swift`, `ShaarDevToolsSmokeLook.swift`, `ShaarDevToolsSmokeMedia.swift`, `ShaarDevToolsSmokeRoundTwo.swift`, and the hidden `shaar.devtools.legacyShell` default. `ShaarPhase2Model.swift` and `ShaarPhase2NativeTransport.swift` go with the shell once nothing calls them.

`DevToolsPanelsProbe.swift` and `DevToolsProbe.swift` go with the panels they drive. `DevToolsDockProbe.swift` and `DevToolsRouteProbe.swift` stay with the dock and the public shortcut.

Remove a projection patch from the Chromium 155 list only after the stock frontend shows the behavior it papered over:

`0017` `0022` `0026` `0028` `0035` `0036` `0037` `0038` `0039` `0040` `0041` `0042` `0043` `0044-shaar-devtools-heap-snapshot-limit.patch` `0046` `0049` `0051` `0052` `0053` `0054` `0056` `0058` `0059` `0060`

`0044-shaar-quit-cancellation-callback.patch` stays. Keep `0010` (dock), `0014` (155 theme), `0064-shaar-devtools-theme-157.patch` (157 theme), `0015` and `0033` (framework extensions), `0016` (agent bridge), `0018` (owned-tab route), `0020` `0021` `0023` `0029` (safe area and viewports), `0024` (network rules), `0025` (repro screencast), and `0034` (force pseudo-state for the Inspector).

Related: [[Shaar_DevTools_Frontend_Panel]], [[Shaar_Inspector]], [[Engine_Module_devtools]].
