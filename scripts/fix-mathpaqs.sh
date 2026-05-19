#!/bin/sh
#  Workaround for mathpaqs crate bug: universal_matrices.ads is a generic-only
#  package spec with no body.  When sdata-core (a library project) depends on
#  mathpaqs (a non-library project), gprbuild tries to recompile every mathpaqs
#  source with sdata-core's flags and fails on this spec.
#
#  Fix: add "for Externally_Built use True;" to every mathpaqs*.gpr file in the
#  Alire build cache so that gprbuild treats mathpaqs objects as already built
#  and skips recompilation.
#
#  This script is run as an Alire pre-build action.  It is idempotent.
#
#  If a future mathpaqs release declares itself a library project (the correct
#  long-term fix), this script becomes a no-op.

set -e

patch_gpr () {
    GPR="$1"
    PROJECT_DECL="$2"

    if grep -q 'Externally_Built' "$GPR"; then
        echo "fix-mathpaqs.sh: already patched $GPR" >&2
        return 0
    fi

    sed -i "s|^${PROJECT_DECL}\$|${PROJECT_DECL}\n   for Externally_Built use \"True\";|" "$GPR"
    echo "fix-mathpaqs.sh: patched $GPR" >&2
}

BUILDS="${ALIRE_BUILD_PREFIX:-${HOME}/.local/share/alire/builds}"

# Patch every mathpaqs version present in the build cache.
find "$BUILDS" -name "mathpaqs.gpr" -path "*/mathpaqs_20*" 2>/dev/null | while IFS= read -r GPR; do
    patch_gpr "$GPR" "project Mathpaqs is"
done

find "$BUILDS" -name "mathpaqs_project_tree.gpr" -path "*/mathpaqs_20*" 2>/dev/null | while IFS= read -r GPR; do
    patch_gpr "$GPR" "project Mathpaqs_Project_Tree is"
done
