#!/usr/bin/env bash
# Container CLI for oci_load, when the answer must be podman.
#
# rules_oci's generated loader probes `command -v docker` first and only falls back to
# podman if that fails. On a host where a docker CLI is installed but its socket is not
# reachable, the probe succeeds and the load then dies with "permission denied while
# trying to connect to the docker API at unix:///var/run/docker.sock". Naming a loader
# explicitly avoids depending on which CLIs happen to be on PATH.
set -euo pipefail
exec podman "$@"
