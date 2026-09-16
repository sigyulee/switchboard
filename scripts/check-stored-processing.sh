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
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/switchboard-stored-processing.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT
python3 - "$configuration" "$check_directory" <<'PY'
from pathlib import Path
import subprocess, sys
binary = Path('.build/arm64-apple-macosx') / sys.argv[1]
objects = []
for target in ['BridgeCore', 'RecorderKit', 'TranscriptKit']:
    found = sorted((binary / (target + '.build')).glob('*.swift.o'))
    if not found:
        sys.exit(f'Missing {target} artifacts; build BridgeChecks first.')
    objects.extend(map(str, found))
executable = Path(sys.argv[2]) / 'StoredProcessingChecks'
subprocess.run([
    'xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
    '-target', 'arm64-apple-macosx26.0', '-module-cache-path', '.build/stored-processing-clang-cache',
    '-I', str(binary / 'Modules'),
    'Sources/Switchboard/StoredProcessingController.swift', 'Sources/Switchboard/TextKey.swift',
    'Tests/StoredProcessingControlsChecks.swift', *objects,
    '-o', str(executable),
], check=True)
subprocess.run([str(executable)], check=True)
PY
