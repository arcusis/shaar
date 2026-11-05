# Third-party notices

Shaar's app bundle includes a SHA-256-pinned Shaar Chromium engine distribution
and Public Suffix List data. License and component credits for the exact bundled
Chromium framework remain available at `chrome://credits`.

## Chromium and bundled dependencies

- **Component:** Chromium 155.0.8059.84 in Chromium Framework.
- **Source:** [Shaar engine pin](ThirdParty/ChromiumEngine/pin.json).
- **License:** Chromium uses BSD-style terms and includes components under
  additional licenses. Preserve the framework's component credits with any
  redistributed build.

## Public Suffix List

- **Component:** `effective_tld_names.dat`, included as a BrowserCore resource.
- **Source:** Chromium source repository, commit and source path recorded in
  [Public Suffix pin](ThirdParty/PublicSuffix/pin.json).
- **License:** MPL-2.0.
- **License text:** [ThirdParty/PublicSuffix/LICENSE](ThirdParty/PublicSuffix/LICENSE).
