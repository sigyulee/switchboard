#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 ]]; then
    printf 'Usage: %s [debug|release]\n' "$0" >&2
    exit 2
fi
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) exit 2 ;; esac
bash scripts/check-toolchain.sh
bash scripts/swift.sh build --configuration "$configuration" --target BridgeCore
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/switchboard-accessibility-check.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT
python3 - "$configuration" "$check_directory" <<'PY'
from pathlib import Path
import subprocess, sys

binary = Path('.build/arm64-apple-macosx') / sys.argv[1]
temporary = Path(sys.argv[2])
objects = sorted((binary / 'BridgeCore.build').glob('*.swift.o'))
module = binary / 'Modules/BridgeCore.swiftmodule'
if not objects or not module.is_file():
    sys.exit(f'Missing BridgeCore {sys.argv[1]} build artifacts.')
executable = temporary / 'AccessibilityChecks'
subprocess.run([
    'xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
    '-target', 'arm64-apple-macosx26.0', '-module-cache-path', '.build/accessibility-clang-cache',
    '-I', str(binary / 'Modules'),
    'Sources/Switchboard/TextKey.swift',
    'Sources/Switchboard/AppTypography.swift',
    'Sources/Switchboard/AccessibilitySupport.swift',
    'Sources/Switchboard/AccessibleStatusView.swift',
    'Tests/AccessibilityChecks/AccessibilityChecks.swift',
    *map(str, objects), '-o', str(executable),
], check=True)
subprocess.run([str(executable)], check=True)
PY
