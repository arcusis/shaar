# Settings design reference

Arc's macOS Settings window informs Shaar's native settings layout. The reference uses a dedicated window, category navigation, grouped controls, and restrained selection styling. Shaar applies these general design principles in its own SwiftUI/AppKit interface; this note does not reproduce Arc documentation or claim pixel-level or behavioral parity. Source links appear in [[Arc_Reference_Library]].

Settings controls must correspond to implemented behavior. Profile owns browser and account data and preferences; Space owns tab organization and theme, and references a Profile. Spaces that intentionally share a Profile also share its account data and Profile preferences. Changing the selected Profile in Settings changes the preference target without switching any browser window's active account.


Screenshots can establish static layout, not animation timing, keyboard focus, or physical input behavior. Verify those separately on supported macOS versions.

Related: [[Profile_Space_Isolation]], [[Arc_Reference_Library]], [[Project_State]].
