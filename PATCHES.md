# Patches

The glibc build runs dsh on the official Node.js **linux-arm64** binary via
Termux's `grun`. Because `process.platform === "linux"`, npm resolves the
**linux-arm64 prebuilt** native modules (koffi, node-pty, sharp) automatically
— no source compilation, no bionic-specific fixes.

That leaves exactly **two** patches, both for the same root cause: **Android's
kernel SELinux forbids hard links in app-private storage**. The dsh session
store and the write tool both publish files with `link()` + `unlink()`; on
Android that fails with `EACCES`. The patches make them fall back to
`rename()` when the platform denies linking.

These patches apply to the **compiled `lib` files inside `node_modules`**
(npm packages ship built JS), not to the TypeScript source.

| Patch | Target (in `node_modules/@deepseek-ai/...`) | Problem | Fix |
|---|---|---|---|
| `npm-dsh-session-persistence-jsonl-link-rename.patch` | `dsh-session-persistence-jsonl/lib/index.js` | session save fails `EACCES: link` | fall back to `rename()` on EACCES/EPERM/ENOTSUP/EOPNOTSUPP |
| `npm-dsh-fs-local-link-rename.patch` | `dsh-fs-local/lib/index.js` | write tool fails `EACCES` (`createIfAbsent` publishes via `link()`) | fall back to `rename()` on platform link denials |

## Upstream anchors

The patch pre-image files are byte-identical across the published dsh
releases tested so far — `@deepseek-ai/dsh` `0.1.0-rc.7`, `0.1.0-rc.8`,
`0.1.1-rc.1` and `0.1.1-rc.2` (verified by hashing `lib/index.js` from the
npm tarballs) — so one patch file keeps applying across those releases. When
a dsh update changes these lib files, `scripts/03-apply-patches.sh` or
`scripts/update-dsh.sh` fails loudly instead of shipping unpatched libs, and
the CI `verify` workflow catches the same drift on every push by applying the
patches to the newest npm release. Regenerate a patch:

```sh
# in a scratch dir with the glibc node (see scripts/01, 02)
#
# PIN THE VERSION: these sub-packages' `latest` dist-tag lags behind the
# monorepo releases (e.g. latest=0.0.1-rc.1 while next=0.1.1-rc.2), so a bare
# `npm pack` fetches the wrong file. Use the same spec update-dsh.sh installed:
npm pack @deepseek-ai/dsh-session-persistence-jsonl@<version>   # e.g. @next or @0.1.1-rc.2
npm pack @deepseek-ai/dsh-fs-local@<version>
tar xzf <pkg>.tgz
# hand-apply the same fix to package/lib/index.js, then:
git diff --no-index <orig> <fixed>   # or use a tiny git repo + git diff
```

When upstream merges these fixes (or ships hard-link support for Android),
delete the corresponding patch file and its reference in
`scripts/patch-lib.sh` (`DSH_PATCH_SET`).

## How the patches are applied

Every caller — `scripts/03-apply-patches.sh`, `scripts/update-dsh.sh`,
`build/build-runtime.sh` and `.github/workflows/build.yml` — goes through
`scripts/patch-lib.sh`, because applying these patches by hand has one sharp
edge:

> `git apply` resolves patch paths against the top of the **enclosing git work
> tree** and silently drops every entry outside the current directory — it
> prints `Skipped patch '...'.` and still **exits 0**.

So the naive form

```sh
(cd "$WORK_DIR" && git apply --directory=node_modules/@deepseek-ai patch)
```

works on a device (the runtime lives outside any repo) but patches *nothing*
when `$WORK_DIR` is inside a git checkout, as it is in CI and in
`build/build-runtime.sh`'s default runtime dir — while reporting success.

`dsh_apply_patch` avoids this by prepending the work dir's prefix inside the
enclosing work tree and by comparing the target's content id before and after,
so an apply that changes nothing fails instead of shipping unpatched libs.

## Deliberately NOT patched (why they work now)

| Old bionic patch | Why it is gone |
|---|---|
| `koffi` spawn.h / statx | glibc has `spawn.h`; and koffi loads `@koromix/koffi-linux-arm64` prebuilt |
| `node-pty` build fixes | glibc node builds it normally, or the `linux-arm64` prebuild is used |
| `sharp` wasm32 | `@img/sharp-linux-arm64` prebuilt is used |
| grep/glob `rg` fallback | glibc node resolves `@vscode/ripgrep-linux-arm64` normally |
