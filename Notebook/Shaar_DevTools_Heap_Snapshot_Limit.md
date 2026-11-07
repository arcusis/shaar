# Heap snapshot size limit

shaar.21 accepts `HeapProfiler.takeHeapSnapshot` and rejects the reply when the collected JSON passes 8MB. A hidden panel probe on the inspector page hits that cap before the 5MB source fixture and before the 20,000-node Elements proof. Patch 0044 raises the cap to 64MB. The live snapshot is not proven until the next engine build includes that patch.

Related: [[Engine_Module_devtools]], [[Shaar_DevTools_Elements_Scale]].
