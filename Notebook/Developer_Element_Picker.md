# Developer element picker

Pick Element in the site control center's Developer section and Command-Option-C toggle a page-only element picker. A transparent page shield intercepts selection before the target's click action; hover shows tag and CSS size. A native panel copies the shortest unique selector among generated CSS candidates, XPath, and a Playwright locator. Test IDs are preferred, then unique role/name or exact text, then CSS. CSS/XPath use standard DOM-document semantics; the Playwright locator can use XPath when its shadow-piercing CSS engine would be broader. Frame locators preserve nested same-origin context; CSS and XPath are relative to the selected frame's document. Escape closes the highlight and panel, including from a same-origin frame. Navigation clears selection. Expanded site controls scroll within available screen height.

React fiber and Vue component metadata supply names and source paths only when the page exposes them. Production builds may omit this information. Cross-origin frame and shadow-root contents are outside this picker. Locator uniqueness checks include open shadow roots; complex accessible names use conservative text/CSS/XPath fallbacks. No source path is opened or executed.

`DeveloperModeProbe` drives trusted renderer input on plain, React 18.3.1, Vue 3.5.22 and nested iframe pages at `developer.localhost`, verifies unique CSS/XPath resolution and exposed component metadata, checks Escape, and renders light/dark native copy panels plus a page highlight capture. Framework scripts and MIT notices are downloaded from integrity-pinned package archives into `build/DeveloperFixtureCache`; they are served only over loopback and are never bundled in Shaar.

After `pnpm --dir Tests/DeveloperPickerTests install --frozen-lockfile --ignore-scripts`, `pnpm --dir Tests/DeveloperPickerTests test` runs additional headless Playwright 1.58.0 contracts against an owned loopback server. Install only its headless shell into the worktree cache with `PLAYWRIGHT_BROWSERS_PATH="$PWD/build/PlaywrightBrowsers" pnpm --dir Tests/DeveloperPickerTests exec playwright install chromium --only-shell`. The 13-case suite validates actual Playwright locator resolution, quote escaping, duplicate/Unicode text, accessible-name ambiguity, open-shadow duplicates and nested frames, and never orders a visible window. Native captures and renderer input do not establish physical keyboard, mouse or clipboard acceptance.

Related: [[Site_Control_Center]], [[Developer_Simulations]], [[Engine_Interop_Boundary]], [[Verification_Harness]].

The Source checks workflow runs the headless contract suite on Linux with Node.js 22 and pnpm 10.24.0 and uploads its source-hashed evidence. Native engine verification remains a separate macOS job.

Offscreen captures: [Light](Assets/Developer_Element_Picker/light.png) · [Dark](Assets/Developer_Element_Picker/dark.png) · [Page highlight](Assets/Developer_Element_Picker/page.png).
