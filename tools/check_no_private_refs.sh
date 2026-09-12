#!/usr/bin/env bash
# Refuse to publish anything that carries a private reference.
#
# This module was extracted from a closed repository, and everything that leaks out of
# such an extraction is textual: an internal hostname left in an example, a package
# server URL in a comment, an absolute path from the developer's machine in a committed
# file. None of them break a build, which is exactly why a check has to look for them
# rather than a test failing.
#
# THE PATTERNS ARE GENERIC, and they live in private_ref_patterns.txt beside this file.
# A committed list of one organisation's hostnames would publish those hostnames, which
# is the thing being prevented. Site-specific literals go in a file of your own, named
# by PRIVATE_REF_PATTERNS_EXTRA, which is read if it is set and is never committed here.
#
# THE SCOPE is the tree as it would be published: files git tracks, plus files that are
# untracked and not ignored, since those are one `git add` away. Whatever git ignores is
# out of scope, which is what keeps bazel-out, a Julia depot and MODULE.bazel.lock from
# being scanned. The pattern files themselves are excluded, since a pattern matches
# itself.
#
# Run it from anywhere in the repository. It exits non-zero listing every hit.
set -euo pipefail

cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

pattern_files=("tools/private_ref_patterns.txt")
[ -z "${PRIVATE_REF_PATTERNS_EXTRA:-}" ] || pattern_files+=("$PRIVATE_REF_PATTERNS_EXTRA")

patterns=()
for f in "${pattern_files[@]}"; do
    [ -f "$f" ] || {
        echo "no pattern file at $f" >&2
        exit 1
    }
    while IFS= read -r line; do
        case "$line" in "" | \#*) continue ;; esac
        patterns+=("$line")
    done < "$f"
done
[ "${#patterns[@]}" -gt 0 ] || {
    echo "no patterns to check for, which cannot be right" >&2
    exit 1
}

files="$(git ls-files --cached --others --exclude-standard |
    grep -vxF -e "tools/private_ref_patterns.txt" -e "${PRIVATE_REF_PATTERNS_EXTRA:-/dev/null}")"
[ -n "$files" ] || {
    echo "no files to check, which cannot be right" >&2
    exit 1
}

status=0
for pattern in "${patterns[@]}"; do
    hits="$(printf '%s\n' "$files" | tr '\n' '\0' |
        xargs -0 grep -InE -- "$pattern" 2> /dev/null || true)"
    if [ -n "$hits" ]; then
        echo "FAILED: this repository is public and /$pattern/ matched:" >&2
        printf '%s\n' "$hits" >&2
        echo >&2
        status=1
    fi
done

if [ "$status" -ne 0 ]; then
    echo "Remove the reference, or narrow the pattern if it is a false positive." >&2
    exit 1
fi

echo "OK: $(printf '%s\n' "$files" | wc -l) files against ${#patterns[@]} patterns, nothing private"
