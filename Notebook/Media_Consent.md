# Media consent and fixture limits

Camera and microphone requests use native consent bound to the requesting origin, selected page, and profile. Grants last for the current visit. Extension installation and media requests share one consent queue; unseen or stale requests cannot be granted. A toolbar indicator lists capturing tabs across spaces and returns to the owning tab. Switching spaces retains active calls. Screen-sharing selection and other website permission types are not implemented; unsupported permission requests are denied.

Media checks use Chromium fake camera/microphone devices and its simulated system-permission backend, restricted to marked disposable probe profiles. They verify separate-profile consent, temporary grants, denial, cancellation on context change, call continuity across space switches, and capture indicators. They never request physical hardware or change real macOS permissions. These checks do not establish Google Meet compatibility or real camera/microphone, screen-sharing, or macOS privacy-prompt behavior.

Related: [[Project_State]].
