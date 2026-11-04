# Private window compositing evidence for #417

The before capture uses production `9d4988d`; the after capture adds this
app-side patch. Both use the pinned `engine-155.0.8059.84-shaar.2` framework,
the same disposable normal profile, and two saved normal tabs. A temporary
diagnostic hook invoked the app's File > New Private Window menu action after
restore and wrote the native view and layer trees. The hook was removed from
the proposed source change.

The Office Mac console was locked during capture. `screencapture -x -l` could
read each private window, but the window could not become key. Both screenshots
show the private shell; they do **not** reproduce David's active-window black
surface. They establish that the fix preserves the blank private UI in this
environment.

The before tree has a full-window `WebContentsViewCocoa` beside the SwiftUI
`NSHostingView` under the native host. The after tree has only the hosting view
there. In both, the hosting view is 1200 × 780, layer backed, and opaque. The
focused engine probe fails on the before structure and passes on the after
structure, including three navigated tabs and search in each phase.
