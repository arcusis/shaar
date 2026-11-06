# DevTools theme evidence for #1081

These offscreen Chromium screenshots show the pinned DevTools frontend CSS before
and after `0014-shaar-devtools-theme.patch` in a fixed docked layout. The mock
uses actual `design_system_tokens.css`, `application_tokens.css`, and the
Elements, Console, Network, tab, filter, and report CSS from the pinned source.

| Panel | Light before | Light after | Dark before | Dark after |
| --- | --- | --- | --- | --- |
| Elements | `before-elements-light.png` | `after-elements-light.png` | `before-elements-dark.png` | `after-elements-dark.png` |
| Console | `before-console-light.png` | `after-console-light.png` | `before-console-dark.png` | `after-console-dark.png` |
| Network | `before-network-light.png` | `after-network-light.png` | `before-network-dark.png` | `after-network-dark.png` |

The browser chrome and panel content are structural mock data. These images
document the intended look and CSS behavior; they are not built-engine or live
DevTools screenshots. In Console, error and warning rows retain their severity
backgrounds. The built frontend must be checked by the engine agent after the
look is approved.
