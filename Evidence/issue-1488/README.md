# Focus order and contrast — offscreen evidence

Hidden launch of `build/Shaar.app`. The window stayed unordered. No new Shaar crash report was written.

Audits has a switch, “Show focus order and contrast”. While it is on, the page shows numbered tab stops and a badge beside text that fails WCAG AA. The shipping engine does not allow `Accessibility.getFullAXTree`, so the page lists the tab order and each node is scored with `DOM.getBoxModel`, `CSS.getComputedStyleForNode`, `CSS.getBackgroundColors`, and `Accessibility.getPartialAXTree`.

## Local page

| | |
| --- | --- |
| Audits before | [panel-before.png](fixture/panel-before.png) |
| Audits after | [panel-after.png](fixture/panel-after.png) |
| Page | [page.png](fixture/page.png) |

Before, the switch is off and the list is empty. After, the list is “3 tab stops · 1 contrast failure”: Priority, First, Second, and 4.48 on “Low contrast”. Skip is disabled and Minus has a negative tabindex, so neither is numbered. “High contrast” and the 24px line are not badged.

## example.com

One tab stop, “Learn more”. No contrast failure. [Audits](example/panel-after.png), [page](example/page.png).

The receipt is [receipt.json](receipt.json).

Probe: `python3 scripts/test-a11y-overlay.py --app build/Shaar.app --evidence Evidence/issue-1488`.
