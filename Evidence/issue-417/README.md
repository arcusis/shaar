# Private window compositing evidence for #417

The before capture uses production `9d4988d`; the after capture adds this
app-side patch. Both use the pinned `engine-155.0.8059.84-shaar.2` framework,
the same disposable normal profile, and two saved normal tabs. A temporary
diagnostic hook invoked the app's File > New Private Window menu action after
restore and wrote the native view and layer trees. The hook was removed from
the proposed source change.

The Office Mac console was locked during capture. `screencapture -x -l` could
read each private window, but the window could not become key. The before and
after PNGs are visually identical: both show the private shell. They do **not**
reproduce David's active-window black surface. The view and layer tree diff is
the evidence for this patch; the images only show that the blank private UI
still renders while the console is locked.

The before tree has a full-window `WebContentsViewCocoa` beside the SwiftUI
`NSHostingView` under the native host. The after tree has only the hosting view
there. In both, the hosting view is 1200 × 780, layer backed, and opaque. The
focused engine probe fails on the before structure and passes on the after
structure, including three navigated tabs and search in each phase.

## After #532

Production `2b19bec` changed private windows to use the full `BrowserWindow`.
The blank tab now has a `ChromiumPageContainerView` inside the SwiftUI
`NSHostingView<Optional<BrowserWindow>>`. The merge queue's blank-shell audit
still required zero page containers, so it rejected the correct new tree.

`view-tree-after-532.txt` is a visible-window view and layer dump from this
Office Mac using a disposable saved normal profile with four tabs in its
selected Space. A temporary diagnostic hook invoked File > New Private Window
and supplied the saved profile while the console was locked; the hook was
removed before committing. `private-after-532.png` was captured with
`screencapture -x -l 12270`. It shows the private sidebar and toolbar around
the blank Chromium page. The blank page itself is dark in this appearance.
The tree shows `WebContentsViewCocoa` under the page container and no
full-window compositor sibling. The updated audit requires that ownership and
a layer-backed page container even for the first blank tab.
