# Developer simulations

The site control center's Developer section applies phone/tablet dimensions, slow 3G/offline networking, 4×/6× CPU slowdown, location, timezone, language, dark mode and reduced motion to one owned tab through restricted Chromium DevTools calls. Settings are remembered by origin and profile in browser preferences. The toolbar's Simulation badge resets all overrides in one click.

`SiteControlsDeveloperModel` serializes changes and clears previous overrides when a tab changes sites. Navigation reapplies saved settings. The pinned engine detaches idle DevTools callers, which clears overrides; a bounded, overlapping page-promise lease keeps the session attached while simulations run. Reset and tab/window teardown end renewal. Language can require a reload for scripts that cached their initial locale. Location still respects the site's location permission.

`DeveloperModeProbe` exercises page API effects and request/CPU timing at `developer.localhost`, uses a probe-only CDP geolocation permission override to avoid requesting physical location from macOS, checks restart persistence and isolation, and captures the expanded section offscreen in light and dark. The probe also opens and closes the docked built-in DevTools frontend while simulations remain active. CPU checks reuse warmed, calibrated fixed work and compare medians and retain raw timing samples. These probes do not establish physical keyboard or focus behavior.

The built-in inspector initializes CSS media after its dock notification. While it is open, active Shaar dark-mode and reduced-motion settings are checked every 500 ms and reapplied if the frontend replaces them. Closing the inspector or clearing those settings stops this polling.

Related: [[Site_Control_Center]], [[Engine_Interop_Boundary]], [[Verification_Harness]].

Offscreen captures: [Light](Assets/Developer_Simulations/light.png) · [Dark](Assets/Developer_Simulations/dark.png).

Combined site controls: [Light](Assets/Developer_Simulations/site-controls-light.png) · [Dark](Assets/Developer_Simulations/site-controls-dark.png).
