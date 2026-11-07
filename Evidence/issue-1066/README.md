# Shipping tab adoption on shaar.23

Built `build/Shaar.app` with `scripts/bundle-app.sh --with-engine`, then ran `python3 scripts/test-tab-adoption-shipping.py` against the bundled executable. The fixture served the source from `127.0.0.1` and the destination from `localhost`.

Both a trusted `target=_blank` click and a trusted `window.open` click created a new tab in Shaar's session. The adopted tab stayed in the opener's native window and loaded the destination marker. All windows remained hidden, the app exited normally, and no new Shaar, ArcusisBrowser, or Chromium crash report appeared in DiagnosticReports.

The repeatable smoke prints a JSON receipt and writes it to `build/tab-adoption/receipt.json`.
