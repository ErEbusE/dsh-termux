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

Patches are generated against the npm versions they were built for
(`@deepseek-ai/dsh` `0.1.0-rc.7`) and have been verified to apply cleanly to
`0.1.0-rc.8`. When a dsh update changes these lib files,
`scripts/03-apply-patches.sh` or `scripts/update-dsh.sh` reports that a patch
no longer applies. Regenerate it:

```sh
# in a scratch dir with the glibc node (see scripts/01, 02)
npm pack @deepseek-ai/dsh-session-persistence-jsonl   # and dsh-fs-local
tar xzf <pkg>.tgz
# hand-apply the same fix to package/lib/index.js, then:
git diff --no-index <orig> <fixed>   # or use a tiny git repo + git diff
```

When upstream merges these fixes (or ships hard-link support for Android),
delete the corresponding patch file and its reference in
`scripts/03-apply-patches.sh`.

## Deliberately NOT patched (why they work now)

| Old bionic patch | Why it is gone |
|---|---|
| `koffi` spawn.h / statx | glibc has `spawn.h`; and koffi loads `@koromix/koffi-linux-arm64` prebuilt |
| `node-pty` build fixes | glibc node builds it normally, or the `linux-arm64` prebuild is used |
| `sharp` wasm32 | `@img/sharp-linux-arm64` prebuilt is used |
| grep/glob `rg` fallback | glibc node resolves `@vscode/ripgrep-linux-arm64` normally |
