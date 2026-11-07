# Shipping Web Vitals proof

Run from this branch after bundling the pinned engine:

```sh
SHAAR_BUNDLE_SWIFT_JOBS=4 nice -n 10 bash scripts/bundle-app.sh --with-engine
nice -n 10 python3 scripts/test-devtools-smoke.py --app build/Shaar.app --vitals-only
```

The hidden shipping app (`com.arcusis.browser`) with pinned engine shaar.23 loaded the local fixture, measured its page, sent a trusted click to the fixture button, opened DevTools with F12, and displayed LCP 0.44 s and INP 80 ms in the Performance panel. The focused receipt reported 5 passed, 0 failed, no visible windows, and no new crash reports. Values vary slightly between runs.

The offscreen panel capture is [after-vitals.png](after-vitals.png).
