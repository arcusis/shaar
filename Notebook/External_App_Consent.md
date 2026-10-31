# External application consent

Requests that reach Chromium's external-protocol consent hook enter a native consent queue. The sheet identifies the application, initiating origin, Profile, and scheme. Destination paths, query strings, fragments, credentials, and upstream prompt text are not passed to the UI. Approval applies once and does not create a persistent allowlist or register a handler.

Each request is bound to its native window, tab, Profile, and document generation. Unknown, malformed, duplicate, replayed, stale, or foreign decisions are denied. Navigation, reload, selection change, renderer loss, closure, and shutdown invalidate pending requests. Existing Chromium fallback behavior remains when the host callback is unavailable.

Chromium policy permits some schemes, including `mailto`, before this hook. The feature is not a universal external-link interception layer. Authored fixtures exercise a prompted scheme (`webcal`) and a no-launch resolver; they do not establish coverage of every Chromium dispatch path or operating-system handler.

Related: [[Media_Consent]], [[Native_Window_Ownership]], [[Source_And_Native_Verification]].
