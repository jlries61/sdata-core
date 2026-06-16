#!/bin/sh
#  Build and run sdata-core's in-crate test drivers.
#
#  Run from the project root or from any subdirectory.  Honours
#  GPR_PROJECT_PATH if pre-set (e.g. by a packaging build); otherwise
#  uses `alr exec --` to inherit Alire's dependency paths.

set -eu

#  Locate the project root by walking up from this script.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

GPRBUILD_PREFIX=""
if [ -z "${GPR_PROJECT_PATH:-}" ] && command -v alr >/dev/null 2>&1; then
   GPRBUILD_PREFIX="alr exec -- "
fi

echo "==> Building test drivers"
${GPRBUILD_PREFIX}gprbuild -q -p -P tests/sdata_core_tests.gpr

EXIT_STATUS=0
for driver in values_tests parse_expression_tests call_function_tests statistics_tests commands_tests; do
   echo ""
   if ! tests/bin/"$driver"; then
      EXIT_STATUS=1
      echo "  (driver $driver failed)"
   fi
done

#  Documentation-generator unit tests (Python stdlib only; skipped when
#  python3 is unavailable, e.g. a minimal packaging environment).
if command -v python3 >/dev/null 2>&1; then
   echo ""
   echo "==> Running gen-reference tests"
   if ! python3 scripts/test-gen-reference.py; then
      EXIT_STATUS=1
      echo "  (gen-reference tests failed)"
   fi
else
   echo ""
   echo "==> Skipping gen-reference tests (python3 not found)"
fi

echo ""
if [ "$EXIT_STATUS" -eq 0 ]; then
   echo "==> All test drivers passed."
else
   echo "==> One or more test drivers failed."
fi
exit "$EXIT_STATUS"
