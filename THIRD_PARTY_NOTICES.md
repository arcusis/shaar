# Third-party notices

Shaar's default app bundle includes the pinned ArdiaCore engine distribution,
which contains Chromium and its bundled dependencies, and Public Suffix List
data. Notices below identify source and license. The project does not reproduce
upstream license texts here; follow the listed source notices.

## Chromium and bundled dependencies

- **Component:** Chromium 155.0.8059.84, distributed as the Chromium Framework
  through the pinned ArdiaCore engine archive.
- **Source:** [ArdiaCore pin](ThirdParty/ArdiaCore/pin.json), including archive
  URL and SHA-256.
- **License:** Chromium is distributed under BSD-style terms and includes
  components under additional licenses.
- **Notices:** Complete component-level credits ship inside the framework and
  are shown by Chromium at `chrome://credits`. Preserve these credits with any
  redistributed framework. The license set can vary with Chromium's bundled
  components; consult the credits in the exact engine build being distributed.

## ArdiaCore

- **Component:** ArdiaCore public native API headers and pinned engine
  distribution metadata.
- **Source:** [ArdiaCore repository and pin](ThirdParty/ArdiaCore/pin.json).
- **License:** Apache-2.0.
- **Notices:** [License](ThirdParty/ArdiaCore/LICENSE) and
  [upstream notice](ThirdParty/ArdiaCore/NOTICE).

## Public Suffix List

- **Component:** `effective_tld_names.dat`, included as a BrowserCore resource.
- **Source:** Chromium source repository, commit and source path recorded in
  [Public Suffix pin](ThirdParty/PublicSuffix/pin.json).
- **License:** MPL-2.0.
- **License text:** [ThirdParty/PublicSuffix/LICENSE](ThirdParty/PublicSuffix/LICENSE).

## Optional native Bitwarden SDK build

The standard `Package.swift` configuration does not link the native Bitwarden
SDK. An opt-in local build can include a generated SDK package and its dynamic
library.

- **Component:** Bitwarden SDK internal source and generated native SDK.
- **Source:** [Bitwarden SDK internal repository](https://github.com/bitwarden/sdk-internal),
  commit `5cf919837e83b71c2508bf99344ea57cf5f84e88`, recorded in
  [the lifecycle pin](ThirdParty/BitwardenLifecycleProbe/pin.json).
- **License and terms:** unresolved for distribution. The generated package
  stages upstream `LICENSE`, `LICENSE_GPL.txt`, `LICENSE_SDK.txt`, and
  `DISCLAIMER.md` in `ThirdPartyNotices`; review and retain those exact files
  before distributing an SDK-enabled build. The SDK is experimental and is not
  part of the default app bundle.
