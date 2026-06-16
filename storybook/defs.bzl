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

load(
    "@aspect_bazel_lib//lib:copy_to_directory.bzl",
    "copy_to_directory_bin_action",
)
load("@rules_shell//shell:sh_binary.bzl", _sh_binary = "sh_binary")

_COPY_TO_DIRECTORY_TOOLCHAIN = "@aspect_bazel_lib//lib:copy_to_directory_toolchain_type"

StorybookBuildInfo = provider(
    doc = "A `storybook build` output tree.",
    fields = {
        "tree": "Directory: the storybook-static output.",
    },
)

# -----------------------------------------------------------------------------
# storybook_build — `storybook build` as a shell-free Bazel action.
# -----------------------------------------------------------------------------
#
# Two actions, no `run_shell`:
#   1. Stage (`copy_to_directory_bin_action`): materialize `srcs` + `data` into a
#      real-file TreeArtifact (Bazel otherwise materializes them as a symlink
#      forest back to the read-only workspace, which breaks Vite/webpack realpath
#      resolution for first-party compiled packages).
#   2. StorybookBuild (`ctx.actions.run` over an internal `js_binary` driver):
#      the pure-Node driver makes a writable working copy, re-points node_modules
#      at the realpath'd compiled content store, and invokes Storybook's
#      programmatic `buildStaticStandalone`. This is the bazel-idiomatic
#      replacement for the bash staging that consumers forked locally.

def _storybook_build_impl(ctx):
    out_dir = ctx.actions.declare_directory(ctx.label.name + ".out")
    staged_dir = ctx.actions.declare_directory(ctx.label.name + ".staged")

    app_root = ctx.attr.app_root

    # `copy_to_directory` strips each root_path prefix from the output path.
    # `["."]` would strip the RULE's package — wrong when the target lives in a
    # sub-package (e.g. `.storybook/`) but stages workspace-root-relative srcs
    # that span packages. An empty list strips nothing, preserving repo-relative
    # paths (`.storybook/main.ts`, `stories/…`, `package.json`). A non-empty
    # `app_root` (a self-contained app in one package) strips that prefix.
    root_paths = [app_root] if app_root else []

    copy_to_directory_bin_action(
        ctx,
        name = ctx.label.name + "_stage",
        dst = staged_dir,
        copy_to_directory_bin = ctx.toolchains[_COPY_TO_DIRECTORY_TOOLCHAIN].copy_to_directory_info.bin,
        files = ctx.files.srcs + ctx.files.data,
        root_paths = root_paths,
        # Real copies (default "auto" hardlinks); the driver needs to copy the
        # staged tree into a writable working dir without chasing shared inodes.
        hardlink = "off",
    )

    # aspect_rules_js links the compiled node_modules at <bin>/<app_root>/
    # node_modules (or <bin>/node_modules at the workspace root).
    nm = ctx.bin_dir.path
    if app_root:
        nm += "/" + app_root
    nm += "/node_modules"

    args = ctx.actions.args()
    args.add(staged_dir.path)
    args.add(nm)
    args.add(out_dir.path)
    args.add(ctx.attr.config_dir)

    deps_inputs = depset(transitive = [
        d[DefaultInfo].default_runfiles.files
        for d in ctx.attr.deps
    ])

    ctx.actions.run(
        outputs = [out_dir],
        inputs = depset(direct = [staged_dir], transitive = [deps_inputs]),
        executable = ctx.executable._driver,
        arguments = [args],
        env = {
            "BAZEL_BINDIR": ctx.bin_dir.path,
            "STORYBOOK_DISABLE_TELEMETRY": "1",
            "NODE_ENV": "production",
            # Determinism pins. TZ=UTC normalizes timezone-sensitive formatting
            # in rendered output; SOURCE_DATE_EPOCH is read by esbuild + some
            # Vite plugins for emitted-artifact mtimes.
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
            doc = "All Storybook config + story files + staticDirs content, " +
                  "staged as real files into the build sandbox.",
        ),
        "deps": attr.label_list(
            doc = "Workspace + npm targets the stories/config import. Include the " +
                  "package-local `:node_modules` link tree — its COMPILED " +
                  "packages are what Storybook resolves against.",
        ),
        "config_dir": attr.string(
            default = ".storybook",
            doc = "Storybook config dir, relative to `app_root`.",
        ),
        "app_root": attr.string(
            default = "",
            doc = "Package dir the srcs are rooted at (used for staging + the " +
                  "node_modules path). Empty (the default) = the workspace root.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Extra files to stage alongside srcs.",
        ),
        "_driver": attr.label(
            default = "@rules_storybook//storybook:build_driver",
            executable = True,
            cfg = "exec",
            doc = "The internal shell-free `storybook build` js_binary driver.",
        ),
    },
    toolchains = [_COPY_TO_DIRECTORY_TOOLCHAIN],
    doc = "Run `storybook build` (shell-free, over a real-file staged tree) and " +
          "emit `storybook-static` as a tree artifact.",
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

def storybook_dev(name, port = "6006", prebuilt = {}, **kwargs):
    """`bazel run //...:NAME` invokes `pnpm exec storybook dev`.

    Escapes the runfiles sandbox to run against the live workspace
    source for HMR. Intentionally NOT hermetic — that's `storybook_build`'s
    job. This macro is the dev-loop counterpart.

    Args:
      name: target name.
      port: dev server port. Defaults to `6006`.
      prebuilt: dict of `{repo_relative_dir: target}` — Bazel-built artifacts
        staged into the LIVE workspace at `repo_relative_dir` before
        `storybook dev` starts. The dev server resolves from the workspace (not
        bazel-out), so any prebuilt artifact a Storybook addon asserts (e.g. an
        addon's `dist/` service worker) must be present there. Listing it here
        keeps `bazel run` a single fresh-repo command: it builds the artifact,
        stages it (read-only bazel outputs are made writable), and launches.
        E.g. `{"packages/storybook-addon/dist": "//packages/storybook-addon:bundle"}`.
        The staged dirs should be gitignored (they are build outputs).
      **kwargs: forwarded to the underlying `sh_binary` (e.g. `tags`).
    """
    _sh_binary(
        name = name,
        srcs = ["@rules_storybook//storybook/private:storybook_dev.sh"],
        data = prebuilt.values(),
        env = {
            "STORYBOOK_PORT": str(port),
            "STORYBOOK_PREBUILT_DIRS": ":".join(prebuilt.keys()),
        },
        **kwargs
    )
