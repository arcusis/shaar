# Web Vitals in the performance panel

The performance panel installs a page script that records largest contentful paint and interaction to next paint. The model kept only JavaScript bytes and the request count from that snapshot, so those two cards stayed unavailable while long tasks still recorded.

The snapshot now supplies both times in milliseconds. A later timeline event does not replace a largest-contentful-paint value the snapshot already set. The hidden panels probe trusted-clicks the fixture Save changes button after the long-task read so the interaction observer can see it.

Related: [[Shaar_DevTools_Panel_Stream]], [[Shaar_Inspector_Page_Tools]].
