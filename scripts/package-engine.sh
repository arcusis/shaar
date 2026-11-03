#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd -P)"
output="$repo/build/EngineSource"
receipt="$output/receipt.json"
package_dir="$repo/build/EnginePackage"

python3 - "$repo" "$output" "$receipt" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

repo, output, receipt_path = map(Path, sys.argv[1:])
for path in (repo, output, receipt_path):
    if path.is_symlink():
        raise SystemExit(f"refusing symlink: {path}")
if not output.is_dir() or not receipt_path.is_file():
    raise SystemExit("successful engine build receipt is missing")
if output.stat().st_uid != os.getuid() or stat.S_IMODE(output.stat().st_mode) & 0o077:
    raise SystemExit("engine build output ownership or permissions are unsafe")
receipt = json.loads(receipt_path.read_text())
if receipt.get("status") != "succeeded" or receipt.get("owner", {}).get("repo") != str(repo):
    raise SystemExit("engine build receipt is incomplete or belongs to another checkout")
framework_info = receipt.get("framework")
if not isinstance(framework_info, dict):
    raise SystemExit("engine framework receipt is missing")
framework = output / framework_info.get("path", "")
try:
    framework_real = framework.resolve(strict=True)
    framework_real.relative_to(output.resolve(strict=True))
except (OSError, ValueError):
    raise SystemExit("built framework path escapes the owned output")
if framework.is_symlink() or not framework.is_dir():
    raise SystemExit("built framework is missing or unsafe")
binary = framework / "Versions/A/Chromium Framework"
if binary.is_symlink() or not binary.is_file():
    raise SystemExit("built framework binary is missing or unsafe")
digest = hashlib.sha256(binary.read_bytes()).hexdigest()
if digest != framework_info.get("sha256"):
    raise SystemExit("built framework binary does not match the receipt")
source_commit = receipt.get("pins", {}).get("source", {}).get("commit")
if not isinstance(source_commit, str) or len(source_commit) != 40 or any(
    character not in "0123456789abcdef" for character in source_commit
):
    raise SystemExit("source commit is missing from the build receipt")
print(json.dumps({"framework": str(framework), "sourceCommit": source_commit,
                  "frameworkSha256": digest}, sort_keys=True))
PY

framework="$(python3 - "$receipt" <<'PY'
import json, pathlib, sys
record = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(pathlib.Path("build/EngineSource") / record["framework"]["path"])
PY
)"
framework="$repo/$framework"
source_commit="$(python3 - "$receipt" <<'PY'
import json, pathlib, sys
record = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(record["pins"]["source"]["commit"])
PY
)"
framework_sha="$(shasum -a 256 "$framework/Versions/A/Chromium Framework" | awk '{print $1}')"
package_name="ShaarEngine-$source_commit"
stage="$package_dir/$package_name"
archive="$package_dir/$package_name.zip"

rm -rf "$stage"
mkdir -p "$stage"
ditto "$framework" "$stage/Chromium Framework.framework"
cp "$receipt" "$stage/receipt.json"
cat > "$stage/package.json" <<EOF
{
  "schemaVersion": 1,
  "sourceCommit": "$source_commit",
  "frameworkBinarySha256": "$framework_sha",
  "architecture": "arm64"
}
EOF
rm -f "$archive"
ditto -c -k --sequesterRsrc --keepParent "$stage" "$archive"
rm -rf "$stage"
echo "Engine package: $archive"
