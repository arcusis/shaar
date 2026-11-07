# Page tab adoption

A page `target=_blank` link or `window.open` creates a WebContents Shaar did not open. Patch `0047-shaar-tab-adoption.patch` keeps that WebContents in the opener's hidden window, bumps the engine ABI minor to 9, and emits a tab `opened` event. The bridge loads optional `shaar_tab_find`, registers the tab, and delivers the existing `onNewTab` callback. shaar.21 does not export that symbol, so the hidden reload-window probe (`--probe-reload-window`) reports that the page-created tab was not adopted until the next engine build includes this patch.

Related: [[Native_Window_Ownership]], [[Renderer_Recovery]].
