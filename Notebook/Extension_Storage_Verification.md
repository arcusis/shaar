# Extension storage verification

The MV3 fixture also checks callback-based storage writes/reads, area-local and global change notifications for popup and worker writes, and serialized payload preservation. Per-profile JSON reports include observed event/callback order; the test requires delivery without imposing a relative ordering guarantee.

An independent reactive-cache diagnostic seeds a serialized false value, observes the area-local change event, starts an asynchronous refresh read, awaits the write callback, and records the cached value a route guard would see immediately. It then requires eventual refresh to true. The reports preserve event/read/callback order and accept either immediate guard value; a stale cache is not classified as a broken storage API. The current authored runs observe stale immediate reads in all three profile contexts before and after restart. This illustrates a hazard in the matching [Bitwarden state implementation](https://github.com/bitwarden/clients/blob/browser-v2026.10.0/libs/state-internal/src/state-base.ts); it does not prove that implementation caused the real onboarding failure.

Related: [[Bitwarden_Compatibility]].
