#!/usr/bin/env bash
set -euo pipefail
BIN="${HERDR_BIN_PATH:-herdr}"
exec "$BIN" pane move --help
