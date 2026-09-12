#!/usr/bin/env bash
# A julia_depot `hook`, as a test fixture.
#
# The real use of a hook is arranging depot state that Pkg.instantiate then needs: a
# private registry cloned into the depot, a package-server credential written to
# servers/. That has to happen at fetch time and before instantiate, and the only way to
# test "before" is to leave evidence behind that instantiate cannot have written.
#
# So this one writes a marker into the depot, containing the value of the variable the
# depot named in `hook_environ`. tests/hook_test.sh then checks three things: the marker
# exists (the hook ran), it holds the expected value (hook_environ came through), and it
# is not newer than the stamp instantiate wrote afterwards (the ordering).
#
# It also asserts the two variables the rule documents itself as passing, so a
# regression there fails the fetch rather than going unnoticed.
set -euo pipefail

: "${JULIA_BIN:?julia_depot must run the hook with JULIA_BIN set}"
: "${E2E_HOOK_VALUE:?this hook is declared with hook_environ = [\"E2E_HOOK_VALUE\"]}"

# The depot rule passes JULIA_DEPOT_PATH through only when the launching environment set
# one, which is exactly what instantiate.sh records in stamp.txt, so the same fallback
# has to be applied on both sides for the test to find this file.
depot="${JULIA_DEPOT_PATH:-$HOME/.julia}"
depot="${depot%%:*}"

# The marker is keyed on the Julia version, because every version in the matrix has a
# hooked depot and they all share this ambient depot: one filename would mean the last
# fetch overwrote the others, and the ordering check in the test would then be comparing
# a marker against another version's stamp. Asking JULIA_BIN for the version also proves
# the rule handed over a Julia that runs, not just a variable that is set.
version="$("$JULIA_BIN" --startup-file=no -e 'print(VERSION)')"

dir="$depot/rules_julia_depot_e2e"
mkdir -p "$dir"
printf '%s\n' "$E2E_HOOK_VALUE" > "$dir/hook_marker_$version.txt"
echo "hook: wrote $dir/hook_marker_$version.txt"
