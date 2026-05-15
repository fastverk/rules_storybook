<!-- Generated with Stardoc: http://skydoc.bazel.build -->

User-facing rules for rules_storybook.

Three pieces:

  * `storybook_build` — runs `storybook build` as a Bazel action with
    explicit srcs + deps; output is the `storybook-static/` tree.
    Forces `STORYBOOK_DISABLE_TELEMETRY=1` + reproducibility env vars
    (`TZ=UTC`, `SOURCE_DATE_EPOCH=0`) so the action is deterministic
    across runners.
  * `storybook_manifest` — emits a deterministic JSON manifest of
    story file paths. `.storybook/main.ts` imports the manifest
    instead of globbing, so adding a story triggers an explicit
    Bazel-tracked input change.
  * `storybook_dev` — sh_binary macro: `bazel run //path:dev`
    invokes `pnpm exec storybook dev` against the live workspace
    source (HMR-friendly; not hermetic — intentional, for the
    dev loop).

Targets returning `StorybookBuildInfo` expose the build's output
tree programmatically so future rules (deploy targets, doc-site
extractors) can consume builds without re-running storybook.

<a id="storybook_build"></a>

## storybook_build

<pre>
load("@rules_storybook//storybook:defs.bzl", "storybook_build")

storybook_build(<a href="#storybook_build-name">name</a>, <a href="#storybook_build-deps">deps</a>, <a href="#storybook_build-srcs">srcs</a>, <a href="#storybook_build-data">data</a>, <a href="#storybook_build-storybook_bin">storybook_bin</a>)
</pre>

Run `storybook build` and emit `storybook-static` as a tree artifact.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="storybook_build-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="storybook_build-deps"></a>deps |  Workspace + npm targets imported by stories. Brought into runfiles.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="storybook_build-srcs"></a>srcs |  All Storybook config + story files.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | required |  |
| <a id="storybook_build-data"></a>data |  Additional runtime files (e.g. service worker bundle).   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="storybook_build-storybook_bin"></a>storybook_bin |  Storybook CLI target, typically `:node_modules/storybook/dir`.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |


<a id="storybook_manifest"></a>

## storybook_manifest

<pre>
load("@rules_storybook//storybook:defs.bzl", "storybook_manifest")

storybook_manifest(<a href="#storybook_manifest-name">name</a>, <a href="#storybook_manifest-srcs">srcs</a>, <a href="#storybook_manifest-out">out</a>, <a href="#storybook_manifest-relative_to">relative_to</a>)
</pre>

Emit a deterministic JSON manifest of Storybook story files.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="storybook_manifest-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="storybook_manifest-srcs"></a>srcs |  Story files to enumerate. May over-approximate; only `*.stories.ts(x)` entries land in the manifest.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | required |  |
| <a id="storybook_manifest-out"></a>out |  Output filename. Defaults to `<name>.json`.   | String | optional |  `""`  |
| <a id="storybook_manifest-relative_to"></a>relative_to |  Package-relative root that consumed paths should be expressed against (matches Storybook's `stories: ['../foo.tsx']` convention from `.storybook/main.ts`).   | String | optional |  `".storybook"`  |


<a id="StorybookBuildInfo"></a>

## StorybookBuildInfo

<pre>
load("@rules_storybook//storybook:defs.bzl", "StorybookBuildInfo")

StorybookBuildInfo(<a href="#StorybookBuildInfo-tree">tree</a>)
</pre>

A `storybook build` output tree.

**FIELDS**

| Name  | Description |
| :------------- | :------------- |
| <a id="StorybookBuildInfo-tree"></a>tree |  Directory: the storybook-static output.    |


<a id="storybook_dev"></a>

## storybook_dev

<pre>
load("@rules_storybook//storybook:defs.bzl", "storybook_dev")

storybook_dev(<a href="#storybook_dev-name">name</a>, <a href="#storybook_dev-port">port</a>, <a href="#storybook_dev-kwargs">**kwargs</a>)
</pre>

`bazel run //...:NAME` invokes `pnpm exec storybook dev`.

Escapes the runfiles sandbox to run against the live workspace
source for HMR. Intentionally NOT hermetic — that's `storybook_build`'s
job. This macro is the dev-loop counterpart.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="storybook_dev-name"></a>name |  target name.   |  none |
| <a id="storybook_dev-port"></a>port |  dev server port. Defaults to `6006`.   |  `"6006"` |
| <a id="storybook_dev-kwargs"></a>kwargs |  forwarded to the underlying `sh_binary` (e.g. `tags`).   |  none |


