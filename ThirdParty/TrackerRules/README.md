<!-- This Source Code Form is subject to the terms of the Mozilla Public
   - License, v. 2.0. If a copy of the MPL was not distributed with this
   - file, You can obtain one at https://mozilla.org/MPL/2.0/. -->

# Private tracker domain data

`Resources/Privacy/tracker-domains.json` contains complete domain rules extracted
from seven EasyPrivacy tracking-server files at the recorded Git revision. The
data includes its upstream revision, source-file SHA-256 values, attribution,
and license. Domain entries cover matching hosts and their subdomains in
third-party requests. Conditional, path, wildcard-host, and exception rules are
not imported. This is a domain subset of EasyPrivacy.

The data also includes dedicated Google Analytics and advertising collector
domains identified in [the operator's CSP documentation](https://developers.google.com/tag-platform/security/guides/csp).
These supplemental domains are recorded separately; general-purpose Google
domains are excluded. The runtime revision hashes the effective domain set.

The data is adapted from [the EasyList authors](https://easylist.to/), under
[CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/), one of the
[licenses offered upstream](https://easylist.to/pages/licence.html). Attribution
and license metadata must remain with redistributed or updated domain data.
The extraction and engine code use the repository's MPL-2.0 license.

Update from an explicit upstream commit:

```sh
.venv/bin/python scripts/update-private-trackers.py --revision <full-EasyPrivacy-commit-SHA>
```

Review the generated domain diff and source hashes, then run the tracker-rule
tests and private engine probes. The script rejects mutable branch names and
incomplete source inventories. The browser loads its bundled copy before
creating a private profile; the engine validates updates before replacing the
in-memory rules. No filter-list download runs in a private browsing session.

The rules apply only to off-the-record HTTP(S) requests, WebSocket handshakes
from frames and workers, and WebTransport creation. A narrow socket connector
callback supplies browser-owned context and isolation data to Ardia policies. Site allowances remain in OTR
memory; the host revokes allowances when their granting window closes. New
requests and socket handshakes use the current rules; existing connections can
remain until their owners close. The
engine rejects new requests and redirects once their profile begins shutdown. Runtime verification
must establish these behaviors before the engine asset is published.
