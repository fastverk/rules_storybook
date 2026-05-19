# Changelog

All notable changes to rules_storybook. The format is loosely
[Keep a Changelog](https://keepachangelog.com/) — version headers
mirror the published bazel-registry entries.

## 0.1.0 — initial release

- Initial release of Bazel rules for [Storybook]: hermetic
  `storybook build` plus a deterministic story-manifest generator and
  a sandbox-escaping `storybook dev` runner for the HMR loop.
- `storybook_build` runs `storybook build` as a Bazel action with
  `STORYBOOK_DISABLE_TELEMETRY=1`, `TZ=UTC`, and
  `SOURCE_DATE_EPOCH=0` forced for reproducibility; output is the
  `storybook-static/` tree.
- `storybook_manifest` emits a deterministic JSON manifest of story
  file paths so `.storybook/main.ts`'s `stories: [...]` no longer
  relies on a non-deterministic `glob`; adding a story now triggers an
  explicit Bazel-tracked input change.
- `storybook_dev` macro provides a `bazel run` entry point for
  `pnpm exec storybook dev` against the live workspace source
  (intentionally non-hermetic — HMR + watch + on-demand Vite optim).
