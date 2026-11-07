# Elements DOM drag shipping proof

Both captures came from the same hidden shipping app smoke path, with `#long`
and its first row expanded. The app was bundled with
`scripts/bundle-app.sh --with-engine`; the smoke was run with
`scripts/test-devtools-smoke.py`. No window was shown or focused.

| Engine | DOM drag | Full smoke | Expanded row |
| --- | --- | --- | --- |
| shaar.24 | Failed: row had 0 of 1 children loaded | 118 passed, 1 failed, 1 needs manual | [Before](shaar24-before.png) |
| shaar.25 | Passed: moved “QA row 1” before “QA row 0” | 119 passed, 0 failed, 1 needs manual | [After](shaar25-after.png) |

The shaar.25 run exited 0 and reported no new crash. The manual item is the
certificate sheet on the HTTP fixture.
