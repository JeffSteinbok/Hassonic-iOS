#!/usr/bin/env bash
#
# Validate a config YAML file against the app's real schema — pages, media
# accounts and the speaker-claim block.
#
#   scripts/validate_config.sh hassonic.yaml
#   scripts/validate_config.sh -            # read YAML from stdin
#   scripts/validate_config.sh              # defaults to the bundled fallback
#
# Builds scripts/config-validator, a tiny SwiftPM executable whose sources
# symlink the app's own config types, so it enforces exactly what the app
# enforces and prints the same error text the app shows.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/scripts/config-validator"
TARGET="${1:-$REPO_ROOT/Hassonic/Config.yaml}"

swift build --package-path "$PACKAGE_DIR" >/dev/null
exec "$(swift build --package-path "$PACKAGE_DIR" --show-bin-path)/DashboardValidator" "$TARGET"
