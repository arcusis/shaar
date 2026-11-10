# Agent packet — offscreen evidence

View > Agent packet… builds a redacted packet for the selected element or the whole page and shows the size before Copy or Hand to agent. The hidden window stayed offscreen. No crash report was added.

| Surface | Before | After |
| --- | --- | --- |
| Local card, hidden window | [PNG](before.png) | [PNG](after.png) |

After, the selected element is `#card.special`, the packet is 3.8 KB, four winning CSS rules are kept, the source is `/src/Card.tsx:12`, and the notice says the packet is on the clipboard and the agent bridge is on. The same run then built a packet for example.com. The receipt is [receipt.json](receipt.json).

The accessibility walk ran before SwiftUI laid the panel out, so `panelInHierarchy` is false. The after capture shows the panel.

Offscreen panel renders, Aqua and Dark Aqua, from `AgentCopyPacketTests`:

| Surface | Ready | Building |
| --- | --- | --- |
| Light | [PNG](panel-light.png) | [PNG](panel-building-light.png) |
| Dark | [PNG](panel-dark.png) | [PNG](panel-building-dark.png) |

The packet, the View menu command, and the panel live in the shipping app. The hidden proof launches `build/Shaar Verification.app` and drives `NativeBrowserHost.perform(.agentPacket)`. Shipping binaries do not contain the probe. Registering this inside the Chromium DevTools frontend waits on the #1469 overlay and the Chromium 157 engine.

Probe command: `shaar-heavy python3 scripts/test-agent-copy.py --screenshots build/agent-copy/screenshots`
