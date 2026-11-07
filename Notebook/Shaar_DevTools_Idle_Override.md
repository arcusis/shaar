# Idle override probe

The hidden sensors probe sends `Emulation.setIdleOverride` for an active user, an idle user, and a locked screen, then `Emulation.clearIdleOverride`. An empty error means the page accepted the command. shaar.21 accepts all four. The older shaar.20 script still expects the idle command to be missing, so that script exits on this engine.

Related: [[Engine_Module_devtools]], [[Shaar_DevTools_Panel_Stream]].
