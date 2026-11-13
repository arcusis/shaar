# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Owned Sparkle installer fixtures; native entrypoint is hosted-macOS-only."""

import base64
from contextlib import contextmanager
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import posixpath
import re
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
import xml.etree.ElementTree as ET
import zipfile

from ci_support import ROOT
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, NoEncryption, PrivateFormat, PublicFormat


NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
CASES = ("valid", "wrong-signature", "corrupt-archive")


def sha256(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def fingerprint(directory: Path) -> str:
    records = []
    for path in sorted(directory.rglob("*")):
        name = path.relative_to(directory).as_posix()
        if path.is_symlink():
            if not path.resolve().is_relative_to(directory.resolve()):
                raise ValueError(f"Fixture symlink escapes bundle: {name}")
            records.append([name, "link", str(path.readlink())])
        elif path.is_file():
            records.append([name, "file", sha256(path)])
        elif path.is_dir():
            records.append([name, "directory"])
    if not records:
        raise ValueError("Fixture fingerprint cannot be empty")
    return hashlib.sha256(json.dumps(records, separators=(",", ":")).encode()).hexdigest()


def verify_archive(path: Path, expected: str, size: int | None = None) -> None:
    if not re.fullmatch(r"[0-9a-f]{64}", expected) or sha256(path) != expected:
        raise ValueError("Fixture archive SHA256 mismatch")
    if size is not None and path.stat().st_size != size:
        raise ValueError("Fixture archive size mismatch")
    with zipfile.ZipFile(path) as archive:
        for entry in archive.infolist():
            name = PurePosixPath(entry.filename)
            if name.is_absolute() or ".." in name.parts or "\\" in entry.filename:
                raise ValueError("Fixture archive contains an unsafe path")
            if not name.parts or name.parts[0] not in ("Shaar.app", "__MACOSX"):
                raise ValueError("Fixture archive contains an unexpected root")
            if (entry.external_attr >> 16) & 0o170000 == 0o120000:
                target = archive.read(entry).decode("utf-8")
                resolved = PurePosixPath(posixpath.normpath(str(name.parent / target)))
                if PurePosixPath(target).is_absolute() or "\\" in target or resolved.parts[0] != name.parts[0]:
                    raise ValueError("Fixture archive contains an escaping symlink")
        if archive.namelist().count("Shaar.app/Contents/Info.plist") != 1:
            raise ValueError("Fixture archive needs one top-level Shaar.app")


def download_previous_release(url: str, destination: Path) -> None:
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=60) as response, destination.open("wb") as output:
                shutil.copyfileobj(response, output)
            return
        except urllib.error.HTTPError as error:
            destination.unlink(missing_ok=True)
            if error.code not in {408, 429, 500, 502, 503, 504} or attempt == 2:
                raise
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            destination.unlink(missing_ok=True)
            if attempt == 2:
                raise
        time.sleep(2 ** attempt)


def helper_pids(root: Path, exclude: int) -> list[int]:
    listing = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
    owned = []
    for line in listing.splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) == 2 and fields[0].isdigit():
            pid, executable = int(fields[0]), Path(fields[1])
            if pid != exclude and executable.is_absolute() and executable.resolve().is_relative_to(root.resolve()):
                owned.append(pid)
    return owned


def stop_helpers(root: Path, exclude: int) -> list[int]:
    owned = helper_pids(root, exclude)
    for pid in owned:
        print(f"Stopping owned Sparkle helper PID: {pid}", flush=True)
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return owned


def invoke(arguments: list[str], *, timeout: int = 180, owned: Path | None = None) -> tuple[int, str]:
    process = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print(f"Fixture child PID: {process.pid}; tool: {Path(arguments[0]).name}", flush=True)
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        if owned:
            stop_helpers(owned, process.pid)
        process.kill()  # Exact PID printed immediately after creation.
        output, _ = process.communicate()
        print(output, flush=True)
        raise RuntimeError(f"Fixture tool timed out: {Path(arguments[0]).name}") from None
    print(output, end="", flush=True)
    return process.returncode, output


def checked(arguments: list[str]) -> str:
    status, output = invoke(arguments)
    if status:
        raise RuntimeError(f"Fixture tool failed ({status}): {Path(arguments[0]).name}")
    return output


def extract(path: Path, destination: Path) -> Path:
    checked(["ditto", "-x", "-k", str(path), str(destination)])
    app = destination / "Shaar.app"
    fingerprint(app)  # Reject escaping symlinks before modifying a bundle.
    return app


def write_key(path: Path) -> str:
    key = Ed25519PrivateKey.generate()
    seed = key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(base64.b64encode(seed))
    return base64.b64encode(key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode()


def configure_bundle(app: Path, identifier: str, public_key: str, version: int) -> None:
    path = app / "Contents/Info.plist"
    info = plistlib.loads(path.read_bytes())
    info.update(CFBundleIdentifier=identifier, CFBundleVersion=str(version),
                CFBundleShortVersionString=f"0.0.{version}", SUPublicEDKey=public_key,
                SUEnableAutomaticChecks=False, SUEnableInstallerLauncherService=True,
                SUVerifyUpdateBeforeExtraction=True, SUShowReleaseNotes=False,
                SUFeedURL="http://127.0.0.1/appcast.xml",
                NSAppTransportSecurity={"NSAllowsArbitraryLoads": True})
    path.write_bytes(plistlib.dumps(info))
    checked(["codesign", "--force", "--timestamp=none", "--sign", "-", str(app)])
    checked(["codesign", "--verify", "--deep", "--strict", str(app)])


def add_error_diagnostics(source: str) -> str:
    original = """- (void)showUpdaterError:(NSError *)__unused error acknowledgement:(void (^)(void))acknowledgement
{
    acknowledgement();
}"""
    replacement = """- (void)showUpdaterError:(NSError *)__unused error acknowledgement:(void (^)(void))acknowledgement
{
    NSError *cursor = error;
    for (NSUInteger depth = 0; cursor != nil && depth < 8; depth++) {
        fprintf(stderr, "Fixture SDK error %ld (%s). %s\\n", (long)cursor.code,
                cursor.domain.UTF8String, cursor.localizedDescription.UTF8String);
        cursor = cursor.userInfo[NSUnderlyingErrorKey];
    }
    acknowledgement();
}"""
    if source.count(original) != 1:
        raise ValueError("Pinned Sparkle CLI error callback changed; diagnostic patch requires review")
    return source.replace(original, replacement)


def seal_driver_framework(framework: Path) -> None:
    # SDK helpers authenticate their caller's team. Disposable ad-hoc driver needs ad-hoc helpers too.
    components = ("Versions/B/XPCServices/Installer.xpc", "Versions/B/XPCServices/Downloader.xpc",
                  "Versions/B/Autoupdate", "Versions/B/Updater.app", "")
    for component in components:
        flags = ["--preserve-metadata=entitlements"] if component.endswith("Downloader.xpc") else []
        checked(["codesign", "--force", "--timestamp=none", "--sign", "-", *flags, str(framework / component)])


def build_driver(work: Path, framework: Path, checkout: Path, evidence: Path) -> Path:
    pin = next(item for item in json.loads((ROOT / "Package.resolved").read_text())["pins"]
               if item["identity"].lower() == "sparkle")
    revision = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
    if revision != pin["state"]["revision"]:
        raise ValueError("Sparkle CLI checkout differs from the committed SwiftPM pin")
    framework_info = plistlib.loads((framework / "Resources/Info.plist").read_bytes())
    if framework_info["CFBundleShortVersionString"] != pin["state"]["version"]:
        raise ValueError("Sparkle framework version differs from the committed SwiftPM pin")
    app = work / "Driver.app"
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    copied = contents / "Frameworks/Sparkle.framework"
    checked(["ditto", str(framework), str(copied)])
    seal_driver_framework(copied)
    executable = contents / "MacOS/sparkle-cli"
    sources = checkout / "sparkle-cli"
    original = sources / "SPUCommandLineUserDriver.m"
    diagnostic = work / original.name
    diagnostic.write_text(add_error_diagnostics(original.read_text()))
    (evidence / "sparkle-driver.json").write_text(json.dumps(dict(
        sdkRevision=revision, sdkVersion=pin["state"]["version"],
        originalUserDriverSHA256=sha256(original), compiledUserDriverSHA256=sha256(diagnostic),
        modification="Error-chain logging only; original acknowledgement and updater flow retained"), indent=2) + "\n")
    checked(["xcrun", "clang", "-fobjc-arc", "-fmodules",
             "-DSPU_OBJC_DIRECT=__attribute__((objc_direct))",
             "-DSPU_OBJC_DIRECT_MEMBERS=__attribute__((objc_direct_members))",
             "-F", str(copied.parent), "-framework", "Sparkle", "-framework", "Foundation",
             "-framework", "AppKit", "-Wl,-rpath,@executable_path/../Frameworks",
             "-I", str(sources), str(sources / "main.m"), str(sources / "SPUCommandLineDriver.m"), str(diagnostic),
             "-o", str(executable)])
    info = dict(CFBundleExecutable="sparkle-cli", CFBundleIdentifier=f"org.arcusis.fixture.driver.{uuid.uuid4().hex}",
                CFBundleName="Shaar update fixture", CFBundlePackageType="APPL", CFBundleVersion="1",
                CFBundleShortVersionString="1.0", LSUIElement=True,
                NSAppTransportSecurity={"NSAllowsArbitraryLoads": True})
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    checked(["codesign", "--force", "--timestamp=none", "--sign", "-", str(app)])
    checked(["codesign", "--verify", "--deep", "--strict", str(app)])
    return executable


def appcast(url: str, length: int, signature: str) -> bytes:
    ET.register_namespace("sparkle", NAMESPACE)
    rss = ET.Element("rss", version="2.0")
    item = ET.SubElement(ET.SubElement(rss, "channel"), "item")
    ET.SubElement(item, "title").text = "Fixture update"
    ET.SubElement(item, f"{{{NAMESPACE}}}version").text = "2"
    ET.SubElement(item, f"{{{NAMESPACE}}}shortVersionString").text = "0.0.2"
    ET.SubElement(item, "enclosure", url=url, length=str(length), type="application/octet-stream",
                  attrib={f"{{{NAMESPACE}}}edSignature": signature})
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True)


@contextmanager
def feed_server(archive: Path, signature: str):
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path not in ("/appcast.xml", "/update.zip"):
                self.send_error(404)
                return
            requests.append(self.path)
            self.send_response(200)
            if self.path == "/appcast.xml":
                data = appcast(f"http://127.0.0.1:{self.server.server_port}/update.zip",
                               archive.stat().st_size, signature)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            else:
                self.send_header("Content-Length", str(archive.stat().st_size))
                self.end_headers()
                with archive.open("rb") as source:
                    shutil.copyfileobj(source, self.wfile)

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/appcast.xml", requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def assert_install(case: str, status: int, log: str, requests: list[str], before: str,
                   after: str, expected: str, data_before: str, data_after: str,
                   executable_changed: bool, version: str) -> None:
    if not {"/appcast.xml", "/update.zip"}.issubset(requests):
        raise AssertionError("Updater did not request both feed and archive")
    if data_before != data_after:
        raise AssertionError("Seeded data changed during update")
    if case == "valid":
        if status or "Installation Finished." not in log or after != expected or before == after:
            raise AssertionError("Sparkle did not install the exact candidate payload")
        if not executable_changed or version != "2":
            raise AssertionError("Installed executable/version did not advance")
    elif case in CASES:
        # Sparkle 2.10.1 wraps pre-extraction signature rejection in SUInstallationError (4005).
        code = re.search(r"error (?:300[12]|4005) \(SUSparkleErrorDomain\)", log)
        signature_error = re.search(r"signature.*(?:validation|invalid|failed)", log, re.IGNORECASE)
        if status != 1 or not code or not signature_error:
            raise AssertionError("Negative case did not fail with a Sparkle signature/validation error")
        if after != before or "Installation Finished." in log or version != "1":
            raise AssertionError("Rejected update modified the installed application")
    else:
        raise ValueError("Unknown update case")


def seed_data(directory: Path) -> None:
    directory.mkdir()
    for source in sorted((ROOT / "Tests/Fixtures/Upgrade").glob("*.json")):
        shutil.copyfile(source, directory / source.name)
    if not list(directory.iterdir()):
        raise ValueError("Upgrade data fixtures are missing")


def run_case(case: str, work: Path, previous: Path, candidate: Path,
             driver: Path, signer: Path, evidence: Path) -> dict:
    directory = work / case
    directory.mkdir()
    old = extract(previous, directory / "installed")
    new = extract(candidate, directory / "candidate")
    identifier = f"org.arcusis.fixture.target.{uuid.uuid4().hex}"
    key = directory / "fixture.key"
    public_key = write_key(key)
    configure_bundle(old, identifier, public_key, 1)
    configure_bundle(new, identifier, public_key, 2)
    data = directory / "data"
    seed_data(data)
    before, expected, data_before = fingerprint(old), fingerprint(new), fingerprint(data)
    executable = plistlib.loads((old / "Contents/Info.plist").read_bytes())["CFBundleExecutable"]
    old_executable = sha256(old / "Contents/MacOS" / executable)
    archive = directory / "update.zip"
    checked(["ditto", "-c", "-k", "--keepParent", str(new), str(archive)])
    signing_key = key
    if case == "wrong-signature":
        signing_key = directory / "wrong.key"
        write_key(signing_key)
    signature = checked([str(signer), "--ed-key-file", str(signing_key), "-p", str(archive)]).strip()
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Fixture signing tool did not return an Ed25519 signature")
    signed_digest = sha256(archive)
    if case == "corrupt-archive":
        with archive.open("r+b") as output:
            output.seek(0)
            output.write(b"FAIL")
    with feed_server(archive, signature) as (url, requests):
        status, log = invoke([str(driver), str(old), "--check-immediately", "--feed-url", url,
                              "--user-agent-name", "Shaar-CI-update-fixture", "--verbose"],
                             timeout=180, owned=work)
    (evidence / f"sparkle-{case}.log").write_text(log)
    deadline = time.monotonic() + 10
    while helper_pids(work, -1) and time.monotonic() < deadline:
        time.sleep(0.1)
    if stop_helpers(work, -1):
        raise AssertionError("Sparkle left owned helper processes after completion")
    info = plistlib.loads((old / "Contents/Info.plist").read_bytes())
    after, data_after = fingerprint(old), fingerprint(data)
    changed = old_executable != sha256(old / "Contents/MacOS" / info["CFBundleExecutable"])
    assert_install(case, status, log, requests, before, after, expected,
                   data_before, data_after, changed, info["CFBundleVersion"])
    result = dict(case=case, passed=True, updaterStatus=status, requests=requests,
                  oldPayload=before, expectedPayload=expected, installedPayload=after,
                  dataBefore=data_before, dataAfter=data_after, executableChanged=changed,
                  signedArchive=signed_digest, servedArchive=sha256(archive))
    return result


def run_simulation(evidence: Path) -> None:
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_OS") != "macOS":
        raise RuntimeError("Sparkle installation requires hosted macOS CI")
    candidate = evidence / "Shaar-unsigned-candidate.zip"
    manifest = (evidence / "candidate.sha256").read_text().splitlines()
    entries = dict(line.split("  ", 1)[::-1] for line in manifest)
    if len(entries) != len(manifest) or set(entries) != {candidate.name, "sbom.spdx.json"}:
        raise ValueError("Candidate checksum manifest is incomplete or duplicated")
    verify_archive(candidate, entries[candidate.name])
    if sha256(evidence / "sbom.spdx.json") != entries["sbom.spdx.json"]:
        raise ValueError("Candidate SBOM SHA256 mismatch")
    pin = json.loads((ROOT / "scripts/sparkle-fixture.json").read_text())
    results = dict(candidateSHA256=sha256(candidate), previousRelease=pin, cases=[])
    report = evidence / "sparkle-results.json"
    with tempfile.TemporaryDirectory(prefix="shaar-sparkle-", dir=os.environ.get("RUNNER_TEMP")) as temporary:
        work = Path(temporary).resolve()
        previous = work / "previous.zip"
        download_previous_release(pin["url"], previous)
        verify_archive(previous, pin["sha256"], pin["size"])
        sdk = ROOT / "build/swiftpm/default"
        framework = ROOT / "build/Shaar.app/Contents/Frameworks/Sparkle.framework"
        driver = build_driver(work, framework, sdk / "checkouts/Sparkle", evidence)
        signer = sdk / "artifacts/sparkle/Sparkle/bin/sign_update"
        for case in CASES:
            try:
                results["cases"].append(run_case(case, work, previous, candidate, driver, signer, evidence))
            except Exception as error:
                results["cases"].append(dict(case=case, passed=False, error=str(error)))
            finally:
                if stop_helpers(work, -1):
                    results["cases"][-1].update(passed=False, error="Owned Sparkle helpers remained after case")
                shutil.rmtree(work / case, ignore_errors=True)
            report.write_text(json.dumps(results, indent=2) + "\n")
    if not all(item["passed"] for item in results["cases"]):
        raise RuntimeError("Sparkle installation simulation failed; see sparkle-results.json")
    print("Sparkle: valid installation and both signature rejection cases passed; data preserved.")
