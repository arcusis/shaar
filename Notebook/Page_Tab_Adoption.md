# Page tab adoption

A page `target=_blank` link or `window.open` creates a WebContents Shaar did not open. Patch `0047-shaar-tab-adoption.patch` keeps that WebContents in the opener's hidden window, bumps the engine ABI minor to 9, and emits a tab `opened` event. The bridge loads optional `shaar_tab_find`, registers the tab, and delivers the existing `onNewTab` callback. shaar.23 includes this patch. The shipping app smoke (`scripts/test-tab-adoption-shipping.py`) verifies that trusted clicks on both controls create owned Shaar tabs at the destination origin while every window remains hidden.

Related: [[Native_Window_Ownership]], [[Renderer_Recovery]].
