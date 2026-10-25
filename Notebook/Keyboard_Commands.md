# Native keyboard commands

Command-N creates a new engine-backed window sharing Space/profile/pin definitions, with no copied ordinary tabs. Shift-Command-W closes the focused window. Command-T / Command-L opens the launcher. Command-S toggles the sidebar. Control-Option-[ / ] switches spaces. Arrow keys select launcher results, Return executes, and Escape dismisses. Opening or dismissing the launcher creates no tab.

Command-Comma opens the reusable native Settings window. When Settings owns focus, Command-W and Shift-Command-W close Settings; page commands remain disabled. Settings profile selection changes only the preference target, never the active browser account.

Launcher returns at most ten results, reserving the final slot for Open when input can navigate. Candidate traversal stops when that prefix is full; selected-Space priority, query matching and profile-scoped bookmark/history behavior remain unchanged. Space sorting and the current Space's ordered-tab array still occur before traversal; this does not establish constant-time search or a measured latency guarantee.

Related: [[Find_In_Page]], [[Native_Window_Ownership]].
