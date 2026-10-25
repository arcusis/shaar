# Profiles and Spaces

Each profile has its own persistent engine directory. A new space defaults to a separate profile; explicitly sharing a profile also shares its accounts. Changing spaces retains live tab objects and moves the selected native view. Tabs cannot silently switch to a different profile, and an unknown profile never falls back to the default profile.

Spaces can be renamed, recolored, and removed; removing a shared space closes its tabs across windows, retains the profile's data, and cannot remove the last space. The editor and confirmation show the affected window/tab count. Normal tab closure waits for the engine's beforeunload decision. Profile IDs persist before navigation.

Settings creates unused profiles and renames existing profiles without opening windows, changing browser selections, or copying account data. These edits persist even with no open browser windows. Names are trimmed display metadata; UUIDs identify accounts. New Space can explicitly choose an unused profile or share an existing one. Profile creation has no fixed count limit; persistence tests cover 129 identities.

Related: [[Managed_Workspace_Persistence]], [[Sidebar_Tab_Organization]].
