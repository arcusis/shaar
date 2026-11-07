# Heap snapshot size limit

shaar.21 accepts `HeapProfiler.takeHeapSnapshot` and rejects the reply when the collected JSON passes 8MB. A hidden panel probe on the inspector page hits that cap before the 5MB source fixture and before the 20,000-node Elements proof. Patch `0044-shaar-devtools-heap-snapshot-limit.patch` raises the cap to 64MB and is listed in `source-build.json` after the quit-cancellation patch. shaar.22 was built with that cap. The packaged smoke on shaar.22 completed the heap snapshot.

Related: [[Engine_Module_devtools]], [[Shaar_DevTools_Elements_Scale]].
