#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Inventory an ad-hoc CI candidate and its pinned components as SPDX 2.3 JSON."""

import datetime
import hashlib
import json
import subprocess
from pathlib import Path

from ci_support import ROOT


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def package(identifier: str, name: str, version: str, url: str) -> dict:
    return dict(SPDXID=identifier, name=name, versionInfo=version, downloadLocation=url,
                filesAnalyzed=False, licenseConcluded="NOASSERTION", licenseDeclared="NOASSERTION",
                copyrightText="NOASSERTION")


def main() -> None:
    directory = ROOT / "build/ci/shipping"
    app = ROOT / "build/Shaar.app"
    candidate = directory / "Shaar-unsigned-candidate.zip"
    subprocess.run(["ditto", "-c", "-k", "--keepParent", str(app), str(candidate)], check=True)
    digest = sha256(candidate)
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    pin = json.loads((ROOT / "ThirdParty/ArdiaCore/pin.json").read_text())
    app_package = package("SPDXRef-Shaar", "Shaar unsigned CI candidate", revision, "NOASSERTION")
    app_package["checksums"] = [dict(algorithm="SHA256", checksumValue=digest)]
    app_package["comment"] = "CI-built ad-hoc signed candidate; no Developer ID signature, notarization or Sparkle signing."
    engine = package("SPDXRef-ArdiaCore", "ArdiaCore Chromium", pin["chromiumVersion"], pin["archiveURL"])
    engine["checksums"] = [dict(algorithm="SHA256", checksumValue=pin["sha256"])]
    packages = [app_package, engine]
    for index, dependency in enumerate(json.loads((ROOT / "Package.resolved").read_text())["pins"]):
        packages.append(package(f"SPDXRef-SwiftPM-{index}", dependency["identity"],
                                dependency["state"]["version"], dependency["location"]))
        packages[-1]["sourceInfo"] = f"Git revision {dependency['state']['revision']}"
    files = []
    links = {}
    for path in sorted(app.rglob("*")):
        relative = "./Shaar.app/" + path.relative_to(app).as_posix()
        if path.is_symlink():
            links[relative] = str(path.readlink())
        elif path.is_file():
            files.append(dict(SPDXID=f"SPDXRef-File-{len(files)}", fileName=relative,
                              checksums=[dict(algorithm="SHA256", checksumValue=sha256(path))],
                              licenseConcluded="NOASSERTION", copyrightText="NOASSERTION"))
    relationships = [dict(spdxElementId="SPDXRef-DOCUMENT", relationshipType="DESCRIBES", relatedSpdxElement="SPDXRef-Shaar")]
    relationships += [dict(spdxElementId="SPDXRef-Shaar", relationshipType="DEPENDS_ON", relatedSpdxElement=item["SPDXID"])
                      for item in packages[1:]]
    relationships += [dict(spdxElementId="SPDXRef-Shaar", relationshipType="CONTAINS", relatedSpdxElement=item["SPDXID"])
                      for item in files]
    document = dict(spdxVersion="SPDX-2.3", dataLicense="CC0-1.0", SPDXID="SPDXRef-DOCUMENT",
                    name="Shaar unsigned candidate inventory",
                    documentNamespace=f"https://github.com/arcusis/shaar/sbom/{revision}/{digest}",
                    creationInfo=dict(creators=["Tool: Shaar ci-sbom.py"],
                                      created=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")),
                    packages=packages, files=files, relationships=relationships)
    (directory / "sbom.spdx.json").write_text(json.dumps(document, indent=2) + "\n")
    (directory / "symlinks.json").write_text(json.dumps(links, indent=2) + "\n")
    (directory / "candidate.sha256").write_text(f"{digest}  {candidate.name}\n")
    print(f"Unsigned candidate: {digest}; {len(files)} files, {len(packages)} packages")


if __name__ == "__main__":
    main()
