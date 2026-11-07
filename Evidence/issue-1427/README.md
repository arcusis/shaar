# Load-time document method (#1427)

Hidden shipping-bundle Network captures on local Next.js and MDN. No visible windows or desktop clicks were used.

| Page | shaar.26 | shaar.27 with Shaar Network reconciliation |
| --- | --- | --- |
| Next.js 16 | No document row ([before](next-before.png)) | GET document row ([after](next-after.png)); two repeated runs passed |
| MDN | 200 document row with blank method ([before](mdn-before.png)) | Both document rows show GET 200 ([after](mdn-after.png)) |

The final shaar.27 hidden full DevTools fixture passed 119 checked rows, 0 failed, 1 manual. The final Next.js and MDN real-world runs exited 0 with no crash report. The Network row accepts only when every matching document has GET.
