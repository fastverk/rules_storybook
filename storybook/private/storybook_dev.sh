#!/usr/bin/env bash
# Dev semantics (HMR, watch, on-demand Vite optim) need to escape the
# runfiles sandbox, so we shell out to the workspace's pnpm-installed
# storybook. Hermetic counterpart is the `storybook_build` rule.
#
# Port: read from $STORYBOOK_PORT (set by the storybook_dev macro
# via sh_binary env). Defaults to 6006 if unset.
set -euo pipefail

if [[ -z "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
  echo "error: must be invoked via 'bazel run'" >&2
  exit 1
fi

cd "${BUILD_WORKSPACE_DIRECTORY}"
exec pnpm exec storybook dev \
  --config-dir=.storybook \
  --port="${STORYBOOK_PORT:-6006}" \
  "$@"
