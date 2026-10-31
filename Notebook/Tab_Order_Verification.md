# Tab and folder ordering verification

Ordering checks move existing live tabs between explicitly shared spaces and reject different-profile moves. They compare native tab IDs, document instances, cookies, and storage before/after moves; query the authored MV3 fixture's `chrome.tabs` ordering/pin/active state; exercise bulk pin/unpin transitions; and verify saved order after restart. Native sidebar layouts are captured at normal and minimum window sizes. These checks exercise the model and native engine integration, not actual pointer drag gestures or context-menu input.

Folder checks exercise the native store's drop handlers with real Chromium tabs: nested membership, collapse, path search, subtree moves, cycle/profile rejection, removal without closing pages, extension-visible tab order, and restart restoration. Unit tests cover v1 migration, malformed v2 preservation, stale editor/consent ownership, and deeply nested trees. Offscreen captures cover expanded/collapsed sidebars, compact layout, command search, and the folder editor. Actual native drag, menu, and dialog interactions remain separate acceptance checks.

Related: [[Sidebar_Tab_Organization]].
