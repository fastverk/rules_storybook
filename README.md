# rules_storybook

Bazel rules for [Storybook](https://storybook.js.org/). Hermetic
`storybook build`, deterministic story-manifest generation, plus a
`storybook dev` runner that escapes the sandbox for the HMR-driven dev
loop.

- **`storybook_build`** — runs `storybook build` as a Bazel action; output is the `storybook-static/` tree. Forces `STORYBOOK_DISABLE_TELEMETRY=1` + reproducibility env vars (`TZ=UTC`, `SOURCE_DATE_EPOCH=0`).
- **`storybook_manifest`** — emits a deterministic JSON manifest of story file paths. Replaces the non-deterministic `glob` in `.storybook/main.ts`'s `stories: [...]` config; adding a story file now triggers an explicit Bazel-tracked input change.
- **`storybook_dev`** — `bazel run //path:dev` macro: runs `pnpm exec storybook dev` against the live workspace source. Intentionally non-hermetic (HMR + watch + Vite on-demand optim need filesystem access outside the runfiles tree).

See [docs/defs.md](docs/defs.md) for the full rule reference.

## Install

Add the registry to your `.bazelrc`:

```
common --registry=https://registry.fastverk.com/
common --registry=https://bcr.bazel.build/
```

In your `MODULE.bazel`:

```python
bazel_dep(name = "rules_storybook", version = "0.1.0")
```

You'll also need npm linking that exposes `storybook` as a `js_binary`-compatible target (typically via `aspect_rules_js`'s `:node_modules/storybook/dir`).

## Quick start

```python
load("@rules_storybook//storybook:defs.bzl", "storybook_build", "storybook_dev", "storybook_manifest")

# 1. The build (hermetic, CI-friendly).
storybook_build(
    name = "storybook",
    srcs = glob(["stories/**/*", ".storybook/**/*"]),
    deps = [
        "//packages/some-lib:lib",
        ":node_modules/storybook",
        ":node_modules/react",
    ],
    storybook_bin = ":node_modules/storybook/dir",
)

# 2. Manifest (drives .storybook/main.ts deterministically).
storybook_manifest(
    name = "stories_manifest",
    srcs = glob(["stories/**/*.stories.tsx"]),
    relative_to = ".storybook",
)

# 3. Dev server (escapes the sandbox; bazel run -> pnpm exec storybook dev).
storybook_dev(
    name = "dev",
    port = "6006",
)
```

Consume the manifest from `.storybook/main.ts`:

```ts
import manifest from "./stories-manifest.json";

export default {
  stories: manifest.stories,
  // ...
};
```

## Hermeticity

`storybook_build` runs in a Bazel sandbox with:

- `STORYBOOK_DISABLE_TELEMETRY=1` — no phone-home.
- `NODE_ENV=production` — production code paths.
- `TZ=UTC` + `SOURCE_DATE_EPOCH=0` — deterministic time-sensitive bundle metadata + emitted-artifact mtimes.

Determinism caveats:

- All deps must be **explicit**. Storybook resolves modules via the package-local `node_modules` link, so `deps` must list every workspace lib whose stories live under your `srcs`, plus every npm dep those stories pull in.
- The `storybook_manifest` rule expects pre-sorted srcs (handled internally — paths are lexically sorted before write) and re-emits only `*.stories.ts(x)` entries, so over-approximating the `srcs` glob is safe.

`storybook_dev` is **not hermetic** by design — Storybook's dev server needs HMR + Vite on-demand bundle optim, both of which require live filesystem access outside the runfiles tree.

## Compatibility

- **Bazel**: 7.4+, bzlmod required.
- **Storybook**: 7+ tested. Earlier versions may work; `--output-dir` + `--quiet` flag contracts have been stable.
- **Workspace shape**: assumes `pnpm` for `storybook_dev` (shells out to `pnpm exec storybook dev`).

## Contributing

Reference docs are stardoc-generated. After editing rule docstrings:

```sh
bazel run //docs:update
```

CI gates this via `bazel test //docs/...`.

## License

MIT.
