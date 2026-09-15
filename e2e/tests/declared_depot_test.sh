#!/usr/bin/env bash
# julia.depot with `depot = "{HOME}/..."` instantiates into THAT directory, not the ambient
# depot: env.sh exports the expanded path with a trailing separator (Julia's bundled depots
# stay on the path), the stamp names the same depot, and the packages landed there.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

env_sh="$(abspath "$1")"
stamp="$(abspath "$2")"
rel="$3"

# {HOME} expanded at FETCH time, in the fetching user's environment, which is not the test's
# sandboxed HOME. So the test checks the shape of what was exported (absolute, the template's
# tail, the trailing separator, no placeholder left) and that the stamp and the directory agree
# with it, rather than recomputing the path from its own HOME.
exported="$(
    # shellcheck disable=SC1090
    . "$env_sh"
    printf '%s\n' "${JULIA_DEPOT_PATH:-}"
)"
case "$exported" in
    /*"/$rel:") ;;
    *) fail "env.sh exports JULIA_DEPOT_PATH=$exported, expected an absolute path ending in /$rel: (expanded {HOME}, trailing separator)" ;;
esac
case "$exported" in
    *"{HOME}"*|*"{USER}"*) fail "env.sh still carries a placeholder: $exported" ;;
esac
[ "$(stamp_value "$stamp" depot)" = "$exported" ] ||
    fail "stamp says depot=$(stamp_value "$stamp" depot) but env.sh exports $exported"
depot="${exported%:}"
[ -d "$depot/packages" ] ||
    fail "$depot has no packages/; the fetch did not instantiate into the declared depot"

echo "PASS: declared depot $depot"
