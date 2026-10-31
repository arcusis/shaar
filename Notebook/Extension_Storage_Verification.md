# Extension storage verification

The MV3 fixture verifies callback-based storage reads and writes, area-local and global change notifications, and serialized payload preservation across popup and worker contexts. It records event and callback order without requiring a specific relative ordering.

A reactive-cache diagnostic verifies that storage change notifications may precede a consumer's refreshed cache value. Consumers must await the refresh before relying on updated state. This test describes extension-storage behavior in the fixture; it does not establish a cause for extension onboarding behavior.

Related: [[Bitwarden_Compatibility]].
