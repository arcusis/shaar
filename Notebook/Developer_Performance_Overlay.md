# Developer performance overlay

The site control center's Developer section and Command-Option-P toggle a movable native overlay on the selected page card. It starts off. A one-second poll combines Chromium `Performance.getMetrics` heap measurements with buffered page `PerformanceObserver` entries for LCP, INP, CLS and resources, plus `requestAnimationFrame` frame counts. Navigation clears native samples and starts fresh observers; closing the overlay disconnects observers and ends its session lease when no simulation remains.

Vital colors follow [web.dev thresholds](https://web.dev/articles/vitals): LCP ≤2.5 s is good and >4 s poor; INP ≤200 ms is good and >500 ms poor; CLS ≤0.1 is good and >0.25 poor. Missing metrics remain unavailable. INP groups event durations by interaction and drops one worst interaction per 50. CLS uses the maximum session window with one-second gaps and five-second duration. These are current-navigation diagnostics, not field percentile scores. Cross-origin transfer sizes require timing permission and may be unavailable.

`DeveloperModeProbe` forces a layout shift, makes a slow loopback request, sends trusted renderer input, verifies heap/resource/vital samples and navigation reset, and captures the overlay offscreen in light and dark. Offscreen evidence does not prove physical dragging or keyboard delivery.

Related: [[Developer_Simulations]], [[Site_Control_Center]], [[Verification_Harness]].

Offscreen captures: [Light](Assets/Developer_Performance_Overlay/light.png) · [Dark](Assets/Developer_Performance_Overlay/dark.png).
