# Draft release notes — Shaar 0.2.0 / Chromium 157

For app version 0.2.0 after v0.1.0. Final wording must match the signed, QA-approved build. Save prompts are out of this release. iCloud Keychain passkeys are pending David's answer and signed-build proof, so neither is included in the user-facing copy below. English `<li>` lines are the input to `scripts/release.sh --notes`; the Hebrew version is for the user-facing announcement/changelog.

## English

- Shaar now runs on Chromium 157, bringing a newer web engine to everyday browsing.
- Press F12 or Option-Command-I for Chromium Developer Tools, with Shaar panels for viewports, network rules, 3D stacking, focus and more. The old developer tools window has been replaced; Shaar Inspector remains available.
- Inactive tabs can sleep to save memory. Choose when they sleep and which sites stay awake in Settings; pinned, active and playing tabs stay awake.
- Move an ordinary tab between windows by dragging it. Its place in the destination window is preserved.
- Shaar tries HTTPS first and shows a warning before opening a public page over an insecure connection. You can change this for each profile in Settings.
- Website requests for location, notifications, MIDI and protocol handlers now appear in Shaar's permission sheet alongside camera and microphone requests.
- Site icons stay with pinned tabs and Favorites after loading and restart.
- A pinned tab no longer remains in the sidebar after its page closes during a renderer failure.
- Switching Spaces while a page loads keeps its tab in the right profile. Library history loads more reliably, and startup no longer shows a premature download error.
- Picture in Picture starts more reliably when you switch away from a playing video.
- Extension Settings explains when loading an unpacked extension needs a newer Shaar engine.

### Sparkle HTML input

Copy the following lines into the release notes HTML file after release approval. Keep that HTML file outside the tracked release version.

```html
<li>Shaar now runs on Chromium 157, bringing a newer web engine to everyday browsing.</li>
<li>Press F12 or Option-Command-I for Chromium Developer Tools, with Shaar panels for viewports, network rules, 3D stacking, focus and more. The old developer tools window has been replaced; Shaar Inspector remains available.</li>
<li>Inactive tabs can sleep to save memory. Choose when they sleep and which sites stay awake in Settings; pinned, active and playing tabs stay awake.</li>
<li>Move an ordinary tab between windows by dragging it. Its place in the destination window is preserved.</li>
<li>Shaar tries HTTPS first and shows a warning before opening a public page over an insecure connection. You can change this for each profile in Settings.</li>
<li>Website requests for location, notifications, MIDI and protocol handlers now appear in Shaar's permission sheet alongside camera and microphone requests.</li>
<li>Site icons stay with pinned tabs and Favorites after loading and restart.</li>
<li>A pinned tab no longer remains in the sidebar after its page closes during a renderer failure.</li>
<li>Switching Spaces while a page loads keeps its tab in the right profile. Library history loads more reliably, and startup no longer shows a premature download error.</li>
<li>Picture in Picture starts more reliably when you switch away from a playing video.</li>
<li>Extension Settings explains when loading an unpacked extension needs a newer Shaar engine.</li>
```

## עברית

- Shaar פועל כעת על Chromium 157, עם מנוע גלישה חדש יותר לשימוש יומיומי.
- לחיצה על F12 או על Option-Command-I פותחת את כלי הפיתוח של Chromium, עם חלוניות של Shaar לתצוגות מסך, כללי רשת, תצוגת שכבות תלת-ממדית, מיקוד ועוד. חלון כלי הפיתוח הישן הוחלף; Shaar Inspector עדיין זמין.
- לשוניות לא פעילות יכולות להירדם כדי לחסוך בזיכרון. בהגדרות אפשר לבחור מתי יירדמו ואילו אתרים יישארו פעילים; לשוניות מוצמדות, פעילות או כאלה שמשמיעות שמע נשארות ערות.
- אפשר לגרור לשונית רגילה בין חלונות. מקומה בחלון היעד נשמר.
- Shaar מנסה לפתוח אתרים ב-HTTPS תחילה ומציג אזהרה לפני פתיחת דף ציבורי בחיבור לא מאובטח. אפשר לשנות זאת בהגדרות של כל פרופיל.
- בקשות של אתרים לגישה למיקום, להתראות, ל-MIDI ולרישום מטפלי קישורים מופיעות כעת בחלונית ההרשאות של Shaar, לצד בקשות למצלמה ולמיקרופון.
- סמלי האתרים נשמרים בלשוניות מוצמדות ובמועדפים לאחר טעינת הדף והפעלה מחדש.
- לשונית מוצמדת כבר לא נשארת בסרגל הצד לאחר שהדף שלה נסגר בזמן קריסה של תהליך התצוגה.
- מעבר בין מרחבים בזמן שדף נטען משאיר את הלשונית בפרופיל הנכון. היסטוריית הספרייה נטענת באופן אמין יותר, ובהפעלה כבר לא מופיעה הודעת שגיאה מוקדמת על הורדות.
- תמונה בתוך תמונה נפתחת בצורה אמינה יותר כשעוברים מדף שמנגן וידאו.
- הגדרות התוספים מסבירות מתי טעינת תוסף לא ארוז דורשת מנוע Shaar חדש יותר.
