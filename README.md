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

Artifact overrides come in two files: a build-time one naming a directory on the build
host, which is what makes Pkg skip the download, and an image-time one naming the path
inside the image, which is what ships. The image-time file is required whenever the
build-time one is set, since shipping the build file instead would put a host path into
an image whose artifact was deliberately not downloaded.

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

The end-to-end suite runs against every version in its matrix, currently 1.12.7 and
1.13.0, so "works on both" is a thing CI asserts rather than a claim.

## Testing

The tests live in `e2e/`, a separate Bazel module that depends on this one through
`local_path_override`. That is deliberate: what is being tested is the consumer
interface, so the tests consume it the way a consumer does, through `bazel_dep`, the
extension, and the repositories it produces.

```bash
cd e2e
bazel test //...
```

Nothing else is needed. The Julia distributions are fetched and pinned by the module
itself, so no Julia has to be installed to run the suite. It resolves against the
public package server, pinned in `e2e/.bazelrc`, so a shell pointing
`JULIA_PKG_SERVER` at a private mirror does not change what the tests fetch.

Expect around twenty minutes the first time, when the Julia distributions are downloaded
and the depots instantiated, and about six for the whole matrix afterwards. The
expensive tests are the ones that have to be: `image_depot_*` instantiates a clean depot
per scenario, and `sysimage_auto` runs PackageCompiler.

### The matrix

Every Julia version in the matrix gets the same set of tests, tagged `julia<minor>` for
the Julia they run, so a shard needs only that version's toolchain and depot:

```bash
bazel test $(bazel query "attr(tags, 'julia1_13', tests(//...))")
```

For each version: the toolchain produces a Julia of that version that can load its own
stdlib; a depot over a Manifest resolved under it stamps the right version, manifest
hash and depot, and its `env.sh` carries no machine path; a hook runs before instantiate
and sees its `hook_environ`; `image_depot.sh` ships artifacts and no packages in
`artifacts` mode and both in `full`, honours the image prefix and the artifact floor,
and never ships depot credentials; artifact overrides are honoured, and a broken one
fails the build instead of producing an image with two copies of a library; and
`sysimage.sh auto` selects that version's PackageCompiler environment, builds an image,
and that image starts and loads what was baked into it. Across versions, a Manifest
resolved under one Julia is refused by the other in both directions, and a
PackageCompiler environment pinned to the wrong minor is refused before any work starts.

### Adding a Julia version

Four steps, in this order, with 1.14 as the example. The first two need that Julia
installed locally (juliaup is the easy way); nothing after them does.

**One.** The module's PackageCompiler environment for the new minor:

```bash
mkdir -p julia/sysimage/v1.14
cp julia/sysimage/v1.12/Project.toml julia/sysimage/v1.14/
julia +1.14 --project=julia/sysimage/v1.14 -e 'using Pkg; Pkg.instantiate()'
```

**Two.** A test project resolved under that exact Julia, against the PUBLIC server.
`env -u JULIA_PKG_SERVER` matters: a manifest resolved through a private mirror is not
one this repository can publish.

```bash
mkdir -p e2e/projects/v1.14
cp e2e/projects/v1.13/Project.toml e2e/projects/v1.14/
cp e2e/projects/v1.13/BUILD.bazel e2e/projects/v1.14/
env -u JULIA_PKG_SERVER julia +1.14 --project=e2e/projects/v1.14 \
    -e 'using Pkg; Pkg.add([PackageSpec(name = "Bzip2_jll"), PackageSpec(name = "Crayons")])'
```

**Three.** The sha256 in `_KNOWN_SHA256` in `julia/extensions.bzl`, taken from
`https://julialang-s3.julialang.org/bin/checksums/julia-1.14.<patch>.sha256`.

**Four.** The declarations: four repositories in `e2e/MODULE.bazel` (toolchain, depot,
sysimage depot, hook depot), a `julia_version_tests()` call in `e2e/tests/BUILD.bazel`,
a `version_mismatch_test()` call for each pair worth covering, and a row in the matrix
in `.github/workflows/ci.yml`.

### Before pushing

`tools/check_no_private_refs.sh` greps everything git would publish for internal
hostnames, machine paths and credentials. The patterns are generic and live in
`tools/private_ref_patterns.txt`; site-specific literals go in a file of your own named
by `PRIVATE_REF_PATTERNS_EXTRA`, so that list never has to be published to be enforced.
CI runs it, along with `buildifier -mode=check -lint=warn -r .`.

## License

MIT.
