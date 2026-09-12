# rules_julia_depot

A Julia environment pinned to a committed `Manifest.toml`, for Bazel. One repository
rule, one module extension, and the scripts that turn that environment into a sysimage
and into container image layers. No registry, package server, or product is assumed.

## What you get

- `julia.toolchain`: an official Julia distribution, fetched and pinned by sha256, as a
  repository (`@julia_dist//:bin/julia` and `@julia_dist//:dist`).
- `julia.depot`: a repository whose fetch instantiates and precompiles a project into the
  ambient depot, refusing a Manifest resolved under a different Julia, and produces an
  `env.sh` for consumers to source. An optional `hook` runs first, for private registries
  and credentials, with `hook_environ` naming the variables it reads.
- `//julia:image_depot.sh`: instantiates the Manifest into a **clean** depot and tars it
  as an image layer, artifacts-only (for an image with a sysimage) or `full` (packages
  too, for an image that loads from source). Supports hash-keyed artifact overrides for
  locally built binaries.
- `//julia:sysimage.sh` with pinned PackageCompiler environments per Julia minor version
  under `//julia:sysimage_envs`, selected automatically from the running Julia.
- `//oci:podman.sh`: an explicit `oci_load` loader for hosts where a docker CLI exists
  but its socket does not.
- `//julia:artifact_paths.jl`: a measurement tool for artifact closures. Not for building.

## Consuming

```python
bazel_dep(name = "rules_julia_depot", version = "0.1.0")
git_override(
    module_name = "rules_julia_depot",
    remote = "https://github.com/csvance/rules_julia_depot.git",
    commit = "<commit>",
)

julia = use_extension("@rules_julia_depot//julia:extensions.bzl", "julia")
julia.toolchain(name = "julia_dist", version = "1.12.7")
julia.depot(
    name = "my_depot",
    manifest = "//julia:Manifest.toml",
    julia = "@julia_dist//:bin/julia",
    # hook = "//tools:enable_private_registry.sh",
    # hook_environ = ["MY_REGISTRY_TOKEN"],
)
use_repo(julia, "julia_dist", "my_depot")
```

A genrule then sources the depot's `env.sh`, takes Julia by label, and runs one of the
scripts:

```python
genrule(
    name = "depot_layer",
    srcs = ["Project.toml", "Manifest.toml", "@my_depot//:env.sh", "@julia_dist//:dist", "@julia_dist//:bin/julia"],
    outs = ["depot.tar"],
    tools = ["@rules_julia_depot//julia:image_depot.sh"],
    cmd = """
set -euo pipefail
. $(location @my_depot//:env.sh)
export JULIA_BIN="$$(cd "$$(dirname $(location @julia_dist//:bin/julia))" && pwd)/julia"
$(location @rules_julia_depot//julia:image_depot.sh) "$$(dirname $(location Manifest.toml))" "$@"
""",
    tags = ["no-sandbox", "requires-network"],
)
```

`no-sandbox` rather than `local`: both let the action see the depot at its real path,
but `local` also disables remote caching.

## The contract, and its limits

The Manifest determines the closure only when it has no `repo-url` (git-sourced)
entries and every JLL's artifacts are hash-pinned, which is the normal state of a
resolved manifest. The depot rule runs on the ambient depot, so `compiled/` can thrash
between branches with different Manifests; the image script always uses a clean depot.
Neither runs Pkg's resolver: a Manifest is pinned, never re-resolved, by this module.

## Julia versions

Nothing here requires one Julia version. `julia.toolchain` fetches any version: the
sha256 is looked up for versions the module knows (1.11.9, 1.12.7, 1.13.0) and passed
explicitly otherwise. The depot rule pins nothing itself; it enforces that YOUR
Manifest was resolved under the Julia you fetched, so moving to a new Julia is one
change in two places, the toolchain version and a re-resolved manifest, and a mismatch
fails at fetch time with a message rather than producing a subtly different depot.

The one version-specific thing the module ships is the PackageCompiler environment a
sysimage is built with, because PackageCompiler's compat and precompile cache are keyed
on the Julia minor. There is one per minor under `julia/sysimage/v<major>.<minor>/`, and
`sysimage.sh auto` picks the one matching the running Julia, failing with the list of
available ones when yours is missing. Adding a version is a copy and an instantiate:

```bash
cp julia/sysimage/v1.12/Project.toml julia/sysimage/v1.14/
julia +1.14 --project=julia/sysimage/v1.14 -e 'using Pkg; Pkg.instantiate()'
```

Linux x86_64 is what this is used with. Other platforms work by passing `sha256` and
`url` to `julia.toolchain`.

## License

MIT.
