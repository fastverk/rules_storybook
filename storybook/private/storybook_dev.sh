#!/usr/bin/env bash
# Dev semantics (HMR, watch, on-demand Vite optim) need to escape the
# runfiles sandbox, so we shell out to the workspace's pnpm-installed
# storybook. Hermetic counterpart is the `storybook_build` rule.
#
# Port: read from $STORYBOOK_PORT (set by the storybook_dev macro via sh_binary
# env). Defaults to 6006.
#
# Prebuilt staging: $STORYBOOK_PREBUILT_DIRS is a `:`-separated list of
# repo-relative dirs (e.g. `packages/storybook-addon/dist`) carried in this
# binary's runfiles. The dev server resolves modules from the live workspace,
# not bazel-out, so any prebuilt artifact a Storybook addon asserts must be
# copied into the workspace first. We do that here so `bazel run` is a single,
# fresh-repo command: build (via runfiles data) -> stage -> serve.
set -euo pipefail

if [[ -z "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
  echo "error: must be invoked via 'bazel run'" >&2
  exit 1
fi

# Resolve this binary's runfiles root (where the prebuilt data lives).
_rf="${RUNFILES_DIR:-}"
if [[ -z "$_rf" && -n "${RUNFILES_MANIFEST_FILE:-}" ]]; then
  _rf="${RUNFILES_MANIFEST_FILE%/MANIFEST}"
fi
if [[ -z "$_rf" || ! -d "$_rf" ]]; then
  _rf="${0}.runfiles"
fi
_main="${_rf}/_main"

if [[ -n "${STORYBOOK_PREBUILT_DIRS:-}" ]]; then
  IFS=':' read -ra _prebuilt <<< "${STORYBOOK_PREBUILT_DIRS}"
  for _d in "${_prebuilt[@]}"; do
    [[ -z "$_d" ]] && continue
    _src="${_main}/${_d}"
    _dst="${BUILD_WORKSPACE_DIRECTORY}/${_d}"
    if [[ ! -e "$_src" ]]; then
      echo "storybook_dev: WARNING prebuilt dir not found in runfiles: ${_d}" >&2
      continue
    fi
    # Bazel outputs are read-only; make the previous copy writable so we can
    # replace it, copy real files (deref symlinks), then make them writable.
    mkdir -p "$(dirname "$_dst")"
    [[ -e "$_dst" ]] && chmod -R u+w "$_dst" 2>/dev/null || true
    rm -rf "$_dst"
    cp -RL "$_src" "$_dst"
    chmod -R u+w "$_dst"
    echo "storybook_dev: staged ${_d}" >&2
  done
fi

cd "${BUILD_WORKSPACE_DIRECTORY}"
exec pnpm exec storybook dev \
  --config-dir=.storybook \
  --port="${STORYBOOK_PORT:-6006}" \
  "$@"
