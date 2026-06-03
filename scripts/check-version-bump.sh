#!/usr/bin/env bash
# owner: arboretum-as-plugin
# Compatibility entrypoint for the release gate. Historical callers still use
# check-version-bump.sh; the behavior now lives in check-release-gate.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/check-release-gate.sh" "$@"
