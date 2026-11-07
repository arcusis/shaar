# Drop inside an element — offscreen evidence

The hidden `ShaarDOMDropVisualTests` fixture rendered the Elements tree in an unshown window in Aqua and Dark Aqua. No browser window was opened for the captures, and no Chromium engine was built. Images are 860×520.

A line on the row means the drop inserts before that row. A box around the row means the drop makes the node a child of that element. The body row is the target in the after captures.

| Surface | Light | Dark |
| --- | --- | --- |
| No drop target | [before-tree-light.png](before-tree-light.png) | [before-tree-dark.png](before-tree-dark.png) |
| Drop inside body | [after-inside-light.png](after-inside-light.png) | [after-inside-dark.png](after-inside-dark.png) |
| Drop before body | [after-before-light.png](after-before-light.png) | [after-before-dark.png](after-before-dark.png) |

Capture command: `SHAAR_DOM_DROP_CAPTURE=1 nice -n 10 swift test -j 4 --filter ShaarDOMDropVisualTests`.

The move itself is proven by `dropInsideMovesToTheNewParentAndUndoRestoresIt`: a fixture drag of the heading into the body changes the live parent, and undo puts it back. `DOM.moveTo` is already on shaar.20, so this slice does not add an engine patch.
