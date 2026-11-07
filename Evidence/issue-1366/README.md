# Coverage Start and Stop

Both images are offscreen captures from the shipping `build/Shaar.app` with the pinned shaar.22 framework. The window stayed hidden throughout each smoke run.

- `before-coverage.png`: Start is enabled, but the hidden press cannot find the SwiftUI control; `coverage-record` fails.
- `after-coverage.png`: Start and Stop are native controls. The smoke presses them and records one coverage row with used bytes.

The final after run exited 0 with no new crash report. Coverage passed; the full smoke retained 10 unrelated failures, with a split-resize failure replacing the original Coverage failure. The coverage result is in `build/devtools-smoke/coverage-1366-final.json`.
