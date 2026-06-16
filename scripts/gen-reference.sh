#!/bin/sh
#  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
#  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
#  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>
#
#  Generate the HTML programmer's reference for sdata-core's public API.
#  Thin wrapper over scripts/gen-reference.py (Python 3 stdlib only -- no
#  Ada toolchain, no Alire dependency).  Writes a single self-contained
#  HTML page.
#
#  Usage:
#    scripts/gen-reference.sh [OUTPUT_FILE]
#
#  OUTPUT_FILE defaults to docs/api/reference.html (gitignored build output).
#  Extra flags understood by gen-reference.py (e.g. --all) are not forwarded
#  here; call the Python script directly for those.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
out=${1:-"$root/docs/api/reference.html"}

mkdir -p "$(dirname "$out")"
python3 "$here/gen-reference.py" --output "$out" --src "$root/src"
