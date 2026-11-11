# Draft release notes — Chromium 157

For the app release after v0.1.0. Final wording must match the signed, QA-approved build. The iCloud Keychain passkey line is conditional on Apple entitlement/profile approval and a successful signed-build test; omit it otherwise. English `<li>` lines are the input to `scripts/release.sh --notes`; the Hebrew version is for the user-facing announcement/changelog. No version number is baked into the text until the app version is chosen.

## English

- Shaar now runs on Chromium 157, bringing a newer web engine to everyday browsing.
- Press F12 or Option-Command-I for Chromium Developer Tools, with Shaar panels for viewports, network rules, 3D stacking, focus and more.
- Inactive tabs can sleep to save memory. Choose when they sleep and which sites stay awake in Settings; pinned, active and playing tabs stay awake.
- Move an ordinary tab between windows by dragging it. Its place in the destination window is preserved.
- Quitting with a private window open now follows the private browsing close flow more reliably, including a chance to stay when a page asks before closing.
- Shaar tries HTTPS first and shows a warning before opening a public page over an insecure connection.
- Website requests for location, notifications, MIDI and protocol handlers now appear in Shaar's permission sheet alongside camera and microphone requests.
- **Include only after signed-build QA:** iCloud Keychain passkeys are available for supported sign-in sites.

### Sparkle HTML input

Copy the following lines into the release notes HTML file after removing the conditional passkey line if its gate is unmet. Keep this file outside the repository's tracked release version until release approval.

```html
<li>Shaar now runs on Chromium 157, bringing a newer web engine to everyday browsing.</li>
<li>Press F12 or Option-Command-I for Chromium Developer Tools, with Shaar panels for viewports, network rules, 3D stacking, focus and more.</li>
<li>Inactive tabs can sleep to save memory. Choose when they sleep and which sites stay awake in Settings; pinned, active and playing tabs stay awake.</li>
<li>Move an ordinary tab between windows by dragging it. Its place in the destination window is preserved.</li>
<li>Quitting with a private window open now follows the private browsing close flow more reliably, including a chance to stay when a page asks before closing.</li>
<li>Shaar tries HTTPS first and shows a warning before opening a public page over an insecure connection.</li>
<li>Website requests for location, notifications, MIDI and protocol handlers now appear in Shaar's permission sheet alongside camera and microphone requests.</li>
```

## עברית

- Shaar פועל כעת על Chromium 157, עם מנוע גלישה חדש יותר לשימוש יומיומי.
- לחיצה על F12 או על Option-Command-I פותחת את כלי הפיתוח של Chromium, עם חלוניות של Shaar לתצוגות מסך, כללי רשת, תצוגת שכבות תלת-ממדית, מיקוד ועוד.
- לשוניות לא פעילות יכולות להירדם כדי לחסוך בזיכרון. בהגדרות אפשר לבחור מתי יירדמו ואילו אתרים יישארו פעילים; לשוניות מוצמדות, פעילות או כאלה שמשמיעות שמע נשארות ערות.
- אפשר לגרור לשונית רגילה בין חלונות. מקומה בחלון היעד נשמר.
- היציאה מ-Shaar כשחלון פרטי פתוח מטפלת בצורה אמינה יותר בסגירת הגלישה הפרטית, כולל אפשרות להישאר כאשר דף מבקש אישור לפני סגירה.
- Shaar מנסה לפתוח אתרים ב-HTTPS תחילה ומציג אזהרה לפני פתיחת דף ציבורי בחיבור לא מאובטח.
- בקשות של אתרים לגישה למיקום, להתראות, ל-MIDI ולרישום מטפלי קישורים מופיעות כעת בחלונית ההרשאות של Shaar, לצד בקשות למצלמה ולמיקרופון.
- **להוסיף רק לאחר בדיקה של גרסה חתומה:** מפתחות גישה של צרור המפתחות של iCloud זמינים באתרים נתמכים לכניסה לחשבון.
