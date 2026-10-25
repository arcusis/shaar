# Library drawer

The sidebar Library button separates hover from click. Hover shows recent downloads and preserves readable-file dragging; click opens an in-window drawer. Its rail contains Spaces, Downloads and Media. Spaces fills available window width with horizontally browsable colored cards and independently scrollable folders/tabs. Selecting a Space or existing tab closes the drawer and keeps the owning window and Profile. Edit and Add Space use existing editors. No Easels, Boosts or Archived Tabs are added.

Downloads and Media capture the active Profile. Search and status/type filters operate on Chromium download records; Media contains downloaded images, videos and PDFs rather than a scan of the laptop or webpage caches. File actions revalidate ownership and readiness. Thumbnail generation uses readable completed files, at most three concurrent requests and a bounded 64-image cache; stale Profile/file results are discarded. Missing previews use native file-type fallbacks.

Command-T, native sheets and consent dismiss the drawer. Profile changes invalidate captured file context. Escape/outside click closes the drawer; normal sidebar visibility is retained. Space tint is confined to the sidebar, and the Space editor previews its draft color without saving before confirmation.

Implementation and acceptance are tracked in [PR #90](https://github.com/arcusis/browser/pull/90), [drawer #86](https://github.com/arcusis/browser/issues/86), [Downloads/Media #87](https://github.com/arcusis/browser/issues/87) and [Spaces overview #88](https://github.com/arcusis/browser/issues/88). Source tests, rendered captures, real thumbnails and physical input remain distinct acceptance evidence.

Related: [[Download_Library]], [[Profile_Space_Isolation]], [[Profile_Favorites]], [[Keyboard_Commands]], [[Arc_Reference_Library]].
