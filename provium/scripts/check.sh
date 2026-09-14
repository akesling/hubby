#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
scripts/format.sh --check
scripts/lint.sh
scripts/test.sh
scripts/verify.sh
