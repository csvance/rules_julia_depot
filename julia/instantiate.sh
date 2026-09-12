#!/usr/bin/env bash
# Bring a Julia depot into agreement with a project's Manifest, and prove it.
#
# Called by the julia_depot repository rule at fetch time. Writes nothing outside the
# depot and the output file it is given.
#
# This runs on the AMBIENT depot (JULIA_DEPOT_PATH, or Julia's default) rather than
# materialising a private content-addressed one: a fresh depot for a large environment
# means tens of gigabytes of artifacts per Manifest change, and the ambient depot already
# has most of them. The trade is that `compiled/` can thrash between branches with
# different Manifests. The image side (image_depot.sh) does build a clean depot, because
# an image must carry exactly the closure and nothing else.
set -euo pipefail

JULIA="${JULIA_BIN:-julia}"   # the depot rule passes the pinned one; PATH keeps this runnable by hand

PROJECT_DIR="$1"   # directory holding Project.toml + Manifest.toml
STAMP_OUT="$2"     # file to write the resolved facts into

"$JULIA" --startup-file=no --project="$PROJECT_DIR" -e '
using Pkg, TOML

# --project is already in force; ask Julia what it resolved rather than re-deriving it.
project = dirname(Base.active_project())
manifest = joinpath(project, "Manifest.toml")
isfile(manifest) || error("no Manifest.toml at $manifest; this rule pins an existing manifest, it does not resolve one")

m = TOML.parsefile(manifest)
want = get(m, "julia_version", nothing)
have = string(VERSION)

# Fail loudly rather than hand back a subtly wrong environment. A Manifest resolved
# under a different Julia can instantiate and then behave differently, which is the
# failure this pin exists to prevent.
if want !== nothing && want != have
    error("Manifest.toml was resolved under Julia $want but this is Julia $have; " *
          "align the toolchain or re-resolve the manifest deliberately")
end

Pkg.instantiate()
Pkg.precompile()
'

# The stamp records what the environment actually is, so a consumer (and a human
# reading a failed build) can see it without re-deriving it.
{
  echo "manifest_sha256=$(sha256sum "$PROJECT_DIR/Manifest.toml" | cut -d' ' -f1)"
  echo "julia_version=$("$JULIA" --startup-file=no -e 'print(VERSION)')"
  echo "host_triplet=$("$JULIA" --startup-file=no -e 'using Base.BinaryPlatforms; print(triplet(HostPlatform()))')"
  echo "depot=${JULIA_DEPOT_PATH:-$HOME/.julia}"
} > "$STAMP_OUT"
