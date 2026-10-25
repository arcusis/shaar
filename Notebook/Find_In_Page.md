# Document-owned Find

Find in Page uses a native bar and Chromium's find API for highlighting, counts, and previous/next matches. Its query belongs to the selected document and is excluded from saved sessions. Changing tab/profile, navigating or reloading, opening consent, or closing the bar clears the search. A different tab starts with an empty query even when its space shares the same profile. The browser does not use a shared Find pasteboard or page scripts to perform matching.

Command-F opens Find in Page. Command-G / Shift-Command-G selects the next/previous match; Return in the find field also selects the next match. Escape or Done closes find and requests focus for its owning page. Live native keyboard/focus behavior still requires an interactive acceptance check.

Find checks search authored fixture text through the real engine, including case-insensitive matching, forward/backward wraparound, rapid query replacement, profile/tab ownership, clearing, and same-URL reload cleanup. The runner also captures native find layouts at normal and minimum window sizes, and captures engine highlights separately. These checks do not prove Find behavior in every web app, PDF, canvas editor, or live native keyboard interaction.

Related: [[Keyboard_Commands]], [[Native_Window_Ownership]].
