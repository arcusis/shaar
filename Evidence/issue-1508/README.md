# Print consent sheet evidence

`before.png` and `after.png` are an offscreen comparison of the page context and the new print consent surface. The after image hosts the production `PrintConsentContent` view. The engine-side `printRequested` event is not present in the currently pinned shipping engine, so this capture demonstrates the app presentation only; it does not claim end-to-end print behavior.

Regenerate with:

```sh
SHAAR_PRINT_EVIDENCE=1 shaar-heavy swift test -j 4 --filter PrintConsentVisualTests
```
