"""User-facing rules for rules_storybook.

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
"""

load("@rules_shell//shell:sh_binary.bzl", _sh_binary = "sh_binary")

StorybookBuildInfo = provider(
    doc = "A `storybook build` output tree.",
    fields = {
        "tree": "Directory: the storybook-static output.",
    },
)

# -----------------------------------------------------------------------------
# storybook_build — `storybook build` as a hermetic Bazel action.
# -----------------------------------------------------------------------------

def _storybook_build_impl(ctx):
    out_dir = ctx.actions.declare_directory(ctx.label.name + ".out")

    args = ctx.actions.args()
    args.add("build")
    args.add("--output-dir", out_dir.path)
    args.add("--quiet")

    ctx.actions.run(
        outputs = [out_dir],
        inputs = depset(direct = ctx.files.srcs + ctx.files.data),
        executable = ctx.attr.storybook_bin.files_to_run.executable,
        arguments = [args],
        env = {
            "STORYBOOK_DISABLE_TELEMETRY": "1",
            "NODE_ENV": "production",
            # Determinism pins. TZ=UTC normalizes timezone-sensitive
            # formatting in story-rendered output; SOURCE_DATE_EPOCH is
            # read by esbuild + some Vite plugins for emitted-artifact
            # mtimes.
            "TZ": "UTC",
            "SOURCE_DATE_EPOCH": "0",
        },
        mnemonic = "StorybookBuild",
        progress_message = "storybook build %s" % ctx.label,
    )

    return [
        DefaultInfo(files = depset([out_dir])),
        StorybookBuildInfo(tree = out_dir),
    ]

storybook_build = rule(
    implementation = _storybook_build_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "All Storybook config + story files.",
        ),
        "deps": attr.label_list(
            doc = "Workspace + npm targets imported by stories. Brought into runfiles.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Additional runtime files (e.g. service worker bundle).",
        ),
        "storybook_bin": attr.label(
            executable = True,
            cfg = "exec",
            mandatory = True,
            doc = "Storybook CLI target, typically `:node_modules/storybook/dir`.",
        ),
    },
    doc = "Run `storybook build` and emit `storybook-static` as a tree artifact.",
)

# -----------------------------------------------------------------------------
# storybook_manifest — deterministic JSON of story file paths.
# -----------------------------------------------------------------------------

def _storybook_manifest_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.out or (ctx.label.name + ".json"))

    relative_root = ctx.attr.relative_to
    if not relative_root.endswith("/"):
        relative_root += "/"

    paths = []
    for f in ctx.files.srcs:
        short = f.short_path
        if not short.endswith(".stories.tsx") and not short.endswith(".stories.ts"):
            continue

        # Express each path relative to `relative_to` so .storybook/main.ts
        # can feed them to Storybook's `stories: [...]` config unchanged.
        if short.startswith(relative_root):
            short = short[len(relative_root):]
        else:
            # Relative-to root isn't a prefix of the file path — walk up
            # one dir per missing component.
            parts = relative_root.rstrip("/").split("/")
            short = "../" * len(parts) + short
        paths.append(short)

    paths = sorted(paths)
    body = "{\n  \"stories\": [\n"
    for i, p in enumerate(paths):
        sep = "," if i < len(paths) - 1 else ""
        body += '    "{}"{}\n'.format(p, sep)
    body += "  ]\n}\n"

    ctx.actions.write(output = out, content = body)
    return [DefaultInfo(files = depset([out]))]

storybook_manifest = rule(
    implementation = _storybook_manifest_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".stories.ts", ".stories.tsx"],
            mandatory = True,
            doc = "Story files to enumerate. May over-approximate; only " +
                  "`*.stories.ts(x)` entries land in the manifest.",
        ),
        "relative_to": attr.string(
            default = ".storybook",
            doc = "Package-relative root that consumed paths should be " +
                  "expressed against (matches Storybook's " +
                  "`stories: ['../foo.tsx']` convention from " +
                  "`.storybook/main.ts`).",
        ),
        "out": attr.string(
            doc = "Output filename. Defaults to `<name>.json`.",
        ),
    },
    doc = "Emit a deterministic JSON manifest of Storybook story files.",
)

# -----------------------------------------------------------------------------
# storybook_dev — sh_binary wrapper around `storybook dev`.
# -----------------------------------------------------------------------------

def storybook_dev(name, port = "6006", **kwargs):
    """`bazel run //...:NAME` invokes `pnpm exec storybook dev`.

    Escapes the runfiles sandbox to run against the live workspace
    source for HMR. Intentionally NOT hermetic — that's `storybook_build`'s
    job. This macro is the dev-loop counterpart.

    Args:
      name: target name.
      port: dev server port. Defaults to `6006`.
      **kwargs: forwarded to the underlying `sh_binary` (e.g. `tags`).
    """
    _sh_binary(
        name = name,
        srcs = ["@rules_storybook//storybook/private:storybook_dev.sh"],
        env = {"STORYBOOK_PORT": str(port)},
        **kwargs
    )
