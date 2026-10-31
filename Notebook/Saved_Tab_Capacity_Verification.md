# Saved-tab capacity verification

Run the dedicated authored native mode with `bash scripts/test-engine.sh --saved-tab-capacity`. This builds the default development bundle; keep running feedback builds at distinct paths. The runner creates fresh marked temporary profiles and executes initial/restart phases against loopback HTTP fixtures. It does not use company accounts or existing browser data.

The managed fixture contains 12 Spaces with 120 pinned/ordinary tabs each (1,440 saved tabs), four profile UUIDs deliberately shared across three Spaces each, nested folders, collapse state and stable selections. It starts one selected native document and visits eight Spaces. Every visited tab keeps its original Chromium tab ID, native view, window owner and authored document instance; every unvisited ID has no native view or owner. Native live count stays at most eight throughout visits, revisits and final selection restoration.

Persistent authored cookies and localStorage markers differ across profiles and match across deliberately shared-profile Spaces. Distinct per-tab sessionStorage markers remain unchanged on each revisit. This does not promise cross-restart sessionStorage durability. Managed metadata, including IDs, URLs/titles, pins, folders and selections, is compared exactly before restart engine attachment. Shutdown checks the owned window, engine and runtime-router cleanup.

Reports bind mode, phase, run identity, counts and cleanup. Capacity-only evidence cannot satisfy the full account/MV3 baseline. Timings are observations, not latency thresholds or total-process memory measurements. This fixture verifies many saved tabs with bounded live documents; hundreds of simultaneous live renderers, physical interaction and company workflows remain separate acceptance gates.

Tracking: [capacity #61](https://github.com/arcusis/shaar/issues/61), [Spaces #3](https://github.com/arcusis/shaar/issues/3), [native performance/distribution #8](https://github.com/arcusis/shaar/issues/8).

Related: [[Profile_Space_Isolation]], [[Managed_Workspace_Persistence]], [[Source_And_Native_Verification]].
