#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# =============================================================================
# update_libsmb2.sh
#
# Points the build hook at a libsmb2 release: reads the release's
# manifest.json (written by libsmb2-scripts' write_manifest.sh) and rewrites
# `_release` and the `_sha256` table in hook/build.dart, the only place the
# package pins its binaries, and copies the manifest to tool/, where
# tool/bindings_drift.dart checks the bindings against its symbol list.
#
# Usage (from the package root):
#   tool/update_libsmb2.sh r9                       # published release
#   tool/update_libsmb2.sh r9 path/to/manifest.json # before publishing it
# =============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE="${1:?usage: tool/update_libsmb2.sh <release, e.g. r9> [manifest.json]}"
TAG="libsmb2-$RELEASE"

if [[ -n "${2:-}" ]]; then
  MANIFEST="$2"
else
  MANIFEST="$(mktemp)"
  trap 'rm -f "$MANIFEST"' EXIT
  curl -fsSL --retry 3 -o "$MANIFEST" \
    "https://github.com/ales-drnz/dart_smb2/releases/download/$TAG/manifest.json"
fi

python3 - "$MANIFEST" "$ROOT/hook/build.dart" "$TAG" <<'PY'
import json, re, sys

manifest_path, hook_path, tag = sys.argv[1:]
manifest = json.load(open(manifest_path))
if f"libsmb2-{manifest['release']}" != tag:
    sys.exit(f"manifest is for libsmb2-{manifest['release']}, not {tag}")

hook = open(hook_path).read()
hook, n = re.subn(r"const _release = '[^']*';", f"const _release = '{tag}';", hook)
if n != 1:
    sys.exit("hook/build.dart: _release not found")

table = re.search(r"const _sha256 = <String, String>\{\n(.*?)\n\};", hook, re.S)
if not table:
    sys.exit("hook/build.dart: _sha256 table not found")
pinned = re.findall(r"'([^']+)':\s*'[0-9a-f]*',", table.group(1))
missing = [name for name in pinned if name not in manifest["assets"]]
if missing:
    sys.exit(f"{tag} has no {', '.join(missing)}")
rows = "\n".join(f"  '{name}':\n      '{manifest['assets'][name]}'," for name in pinned)
hook = hook[:table.start(1)] + rows + hook[table.end(1):]
open(hook_path, "w").write(hook)
print(f"hook/build.dart -> {tag} ({len(pinned)} assets)")
PY

cp "$MANIFEST" "$ROOT/tool/libsmb2_manifest.json"
echo "tool/libsmb2_manifest.json <- $TAG manifest"
