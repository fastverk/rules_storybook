"""`storybook_addon` — build a Storybook addon (addon-kit shape) via Bun.

A Storybook addon ships three entry kinds (see
https://storybook.js.org/docs/addons/writing-addons and
https://github.com/storybookjs/addon-kit):

  * node entries (`preset`)    — build-time config (`viteFinal`, `staticDirs`,
    `managerEntries`/`previewAnnotations`). Runs under Node.
  * manager entries (`manager`) — the manager-UI registration
    (`addons.register`). Runs in the browser; Storybook re-bundles it.
  * preview entries (`preview`)  — decorators / globals / parameters. Runs in
    the preview iframe; Storybook re-bundles it.

`storybook_addon` bundles each entry with `bun_bundle` (rules_bun) — the
esbuild/tsup retirement — and assembles the `dist/*.js` outputs plus the addon
`package.json` into a linkable `npm_package`. The addon `package.json` must carry
the addon-kit `exports` map (`./preset`, `./manager`, `./preview`).

Browser entries keep React + Storybook's own packages external (Storybook
provides them when it re-bundles); node entries keep Storybook external too.
"""

load("@aspect_rules_js//js:defs.bzl", "js_binary", "js_library")
load("@aspect_rules_js//npm:defs.bzl", "npm_package")
load("@rules_bun//bun:defs.bzl", "bun_bundle")

# Storybook injects its own runtime + React into the manager/preview iframes, so
# an addon must NOT bundle them. Trailing-`*` patterns are passed to Bun's
# `--external`.
DEFAULT_BROWSER_EXTERNAL = [
    "react",
    "react-dom",
    "react/jsx-runtime",
    "@storybook/icons",
    "storybook",
    "storybook/*",
    "@storybook/*",
]

# Node-side preset: Storybook (+ its builder) are the runtime; keep them external.
DEFAULT_NODE_EXTERNAL = [
    "storybook",
    "storybook/*",
    "@storybook/*",
]

def _entry_stem(entry):
    """`src/manager.tsx` -> `manager`."""
    base = entry.rsplit("/", 1)[-1]
    return base.rsplit(".", 1)[0]

def storybook_addon(
        name,
        package_name,
        node_modules,
        srcs = [],
        manager_entries = [],
        preview_entries = [],
        node_entries = [],
        external = [],
        package_json = "package.json",
        data = [],
        visibility = None):
    """Bundle a Storybook addon's entries via Bun into a linkable npm_package.

    Args:
      name: target name; also the `npm_package` target.
      package_name: the published npm name (e.g. `@scope/storybook-addon`).
      node_modules: the package-local `:node_modules` link tree label whose
        compiled closure the entries resolve against.
      srcs: all addon source files (`src/**`) the entries import. Bun transpiles
        `.ts`/`.tsx` directly.
      manager_entries: browser manager-UI entry files (e.g. `src/manager.tsx`).
      preview_entries: browser preview entry files (e.g. `src/preview.ts`).
      node_entries: node preset entry files (e.g. `src/preset.ts`).
      external: extra module names/patterns to keep external for every entry.
      package_json: the addon `package.json` (with the addon-kit `exports` map).
      data: extra runfiles for the bundler driver.
      visibility: visibility of the `npm_package`.
    """

    # One driver js_binary stages all srcs + the linked node_modules closure
    # into its runfiles; each entry's bun_bundle re-uses it.
    driver = name + "_bun_driver"
    js_binary(
        name = driver,
        entry_point = "@rules_bun//bun:bun-build-driver",
        data = srcs + [node_modules] + data,
    )

    pkg = native.package_name()
    dist_targets = []

    def _bundle(entry, target, base_external):
        stem = _entry_stem(entry)
        bundle_name = "{}_{}".format(name, stem)
        bun_bundle(
            name = bundle_name,
            driver = ":" + driver,
            entry = "{}/{}".format(pkg, entry) if pkg else entry,
            out = "dist/{}.js".format(stem),
            format = "esm",
            target = target,
            external = base_external + external,
        )
        dist_targets.append(":" + bundle_name)

    for e in node_entries:
        _bundle(e, "node", DEFAULT_NODE_EXTERNAL)
    for e in manager_entries:
        _bundle(e, "browser", DEFAULT_BROWSER_EXTERNAL)
    for e in preview_entries:
        _bundle(e, "browser", DEFAULT_BROWSER_EXTERNAL)

    # Collect the dist/*.js outputs and pack them with the addon package.json.
    js_library(
        name = name + "_dist",
        srcs = dist_targets,
    )
    npm_package(
        name = name,
        srcs = [package_json, ":" + name + "_dist"],
        package = package_name,
        visibility = visibility,
    )
