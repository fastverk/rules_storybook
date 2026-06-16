#!/usr/bin/env node
/**
 * rules_storybook — shell-free `storybook build` driver.
 *
 * Run as the entry point of an aspect_rules_js `js_binary` that `storybook_build`
 * invokes via `ctx.actions.run` (no `run_shell`). The rule stages the app srcs
 * into a real-file TreeArtifact (copy_to_directory) and passes its path plus the
 * compiled `node_modules` path; this driver — pure Node, no `cp`/`ln`/`mkdir`
 * subshell — makes a writable working copy, re-points node_modules at the
 * realpath'd content store, and invokes Storybook's programmatic
 * `buildStaticStandalone` (the same entry the `storybook build` CLI wraps).
 *
 * Why the working copy + re-pointed node_modules symlink: Bazel materializes
 * srcs as a symlink forest back to the (read-only) workspace. Vite/webpack
 * resolution realpaths each module and, for FIRST-PARTY compiled packages, walks
 * to source `.ts` instead of the Bazel-compiled `.js`. A real-file copy plus a
 * node_modules symlink that resolves straight into the compiled content store
 * keeps resolution inside the compiled closure. (Static dirs are staged real
 * files, so the addon never mkdir's into read-only node_modules.)
 *
 * Argv (positional, set by `storybook_build`):
 *   1. stagedRoot     execroot-relative path to the real-file staged app tree
 *   2. nodeModulesSrc execroot-relative path to the compiled `node_modules`
 *   3. outDir         execroot-relative TreeArtifact to populate
 *   4. configDir      Storybook config dir, relative to the app root (".storybook")
 */

import { cpSync, symlinkSync, mkdirSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';

const execroot = process.env.JS_BINARY__EXECROOT || process.cwd();
const [stagedRootArg, nodeModulesArg, outArg, configDirArg = '.storybook'] =
    process.argv.slice(2);

if (!stagedRootArg || !nodeModulesArg || !outArg) {
    console.error('build_driver: usage: build_driver <stagedRoot> <nodeModules> <out> [configDir]');
    process.exit(2);
}

const stagedRoot = path.resolve(execroot, stagedRootArg);
const nodeModulesSrc = path.resolve(execroot, nodeModulesArg);
const outDir = path.resolve(execroot, outArg);

// 1. Real-file working copy of the staged app tree.
const workDir = path.join(tmpdir(), `rules_storybook-${process.pid}`);
mkdirSync(workDir, { recursive: true });
cpSync(stagedRoot, workDir, { recursive: true, dereference: true });

// 2. Point node_modules straight at the realpath'd compiled content store.
symlinkSync(realpathSync(nodeModulesSrc), path.join(workDir, 'node_modules'), 'dir');

// 3. Writable HOME/cache for Storybook + tool tmp writes.
const cacheHome = path.join(workDir, '.cache-home');
mkdirSync(cacheHome, { recursive: true });
process.env.HOME = cacheHome;
process.env.STORYBOOK_DISABLE_TELEMETRY = '1';
process.env.NODE_ENV = process.env.NODE_ENV || 'production';

// 4. Build in-process via the CONSUMER's Storybook (resolved from the linked
//    node_modules), mirroring the CLI's `build.ts` option assembly.
process.chdir(workDir);
const require = createRequire(path.join(workDir, 'noop.cjs'));
const { buildStaticStandalone } = await import(
    pathToFileURL(require.resolve('storybook/internal/core-server'))
);
const { cache } = await import(
    pathToFileURL(require.resolve('storybook/internal/common'))
);
const packageJson = require('storybook/package.json');

try {
    await buildStaticStandalone({
        configDir: path.resolve(workDir, configDirArg),
        outputDir: outDir,
        configType: 'PRODUCTION',
        ignorePreview: false,
        cache,
        packageJson,
    });
} catch (err) {
    console.error('[rules_storybook] storybook build failed:', err?.stack ?? err);
    process.exit(1);
}
