# DevTools panel stream

The panel message stream keeps every console and network event the engine delivers on one turn. The engine flushes that backlog before the shell reads it. A newest-32 buffer dropped the earlier console line, and treating a dropped yield as a closed lease made later lines disappear too. An events-dropped notice means those events are already gone. It does not close the lease, so lines that arrive after the burst still show up.

`consoleBurstStaysOnTheOpenLease` feeds forty console lines, an events-dropped notice, and one more line, and expects every line on the open lease. The hidden panel probe is the live check. This note does not record a new probe result.

Related: [[Engine_Module_devtools]], [[Shaar_DevTools_Hebrew_RTL]].
