# Elements scale proof

The hidden Elements proof inserts 20,000 spans on BODY. Before that, it stops the repro screencast. Stopping the screencast removes the mask style from the page while the document is still small. Left running, that style deletes itself once the page passes 2,000 elements, and the proof reads the missing node as a reloaded tree. The proof waits until the mask is gone and the node count has stayed still, then inserts the spans. It does not lengthen the per-batch wait.

`releaseRecordingStopsTheScreencast` checks that the stop command is the screencast stop for the open lease. The hidden panel probe is the live check. This note does not record a new probe result.

Related: [[Engine_Module_devtools]], [[Shaar_DevTools_Hebrew_RTL]].
