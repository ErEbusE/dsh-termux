# Fixes & adaptations for dsh on Termux

This project runs upstream `dsh` (from npm, never rebuilt from source) inside
Termux. Everything below is an intentional deviation that makes dsh work on
Android; it comes in two kinds:

| Kind | What it means | Emitted by |
|---|---|---|
| **Patch** | edits the compiled npm `lib/*.js` files inside `node_modules` | `scripts/03-apply-patches.sh`, `scripts/update-dsh.sh`, `build/build-runtime.sh` |
| **Environment fix** | no dsh code change — the launcher/installer changes the runtime or environment instead | `configure_glibc_node`, `write_dsh_wrapper`, `write_dsh_opener` in `scripts/common.sh` (sourced by `build/install.sh` from the tarball) |

Both families are guarded by CI on every push. The README keeps only a
one-line table pointing here; this file is where the details live.

## Fix index

| # | Fixes / adapts | One line | Detail |
|---|---|---|---|
| 1 | session saves & write tool fail `EACCES: link` | SELinux forbids hard links in app-private storage; fall back to `rename()` | [Patch 1](#patch-1-hard-link-eacces) |
| 2 | `dsh web` handoff dies; arguments get word-split | `process.execPath` was the glibc loader; launcher now execs node directly | [Fix 2](#fix-2-direct-exec) |
| 3 | `dsh web` finds no browser on Android | `$BROWSER` points at an Android-intent opener | [Fix 3](#fix-3-browser-handoff) |

---

## Part I — Patches (edit dsh's npm lib files)

### Patch 1: hard-link EACCES

Both patches share one root cause: **Android's kernel SELinux forbids hard
links in app-private storage**. The dsh session store and the write tool both
publish files with `link()` + `unlink()`; on Android that fails with
`EACCES`. The patches make them fall back to `rename()` when the platform
denies linking.

They apply to the **compiled `lib` files inside `node_modules`** (npm
packages ship built JS), not to the TypeScript source.

| Patch | Target (in `node_modules/@deepseek-ai/...`) | Problem | Fix |
|---|---|---|---|
| `npm-dsh-session-persistence-jsonl-link-rename.patch` | `dsh-session-persistence-jsonl/lib/index.js` | session save fails `EACCES: link` | fall back to `rename()` on EACCES/EPERM/ENOTSUP/EOPNOTSUPP |
| `npm-dsh-fs-local-link-rename.patch` | `dsh-fs-local/lib/index.js` | write tool fails `EACCES` (`createIfAbsent` publishes via `link()`) | fall back to `rename()` on platform link denials |

#### Upstream anchors

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

#### How the patches are applied

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

#### Deliberately NOT patched (why they work now)

| Old bionic patch | Why it is gone |
|---|---|
| `koffi` spawn.h / statx | glibc has `spawn.h`; and koffi loads `@koromix/koffi-linux-arm64` prebuilt |
| `node-pty` build fixes | glibc node builds it normally, or the `linux-arm64` prebuild is used |
| `sharp` wasm32 | `@img/sharp-linux-arm64` prebuilt is used |
| grep/glob `rg` fallback | glibc node resolves `@vscode/ripgrep-linux-arm64` normally |

---

## Part II — Environment fixes (no dsh code changes)

Two Android/Termux launch facts, neither of which needs a dsh code change.
Both had to be fixed in order: the `execPath` bug kills the opener child
before it can `import('open')`, so the `$BROWSER` wiring stays invisible
until the launcher runs at all.

### Fix 2: direct exec

Node's `process.execPath` is the **glibc loader**, not node, whenever node
runs through `grun` (whose last line is `exec … ld.so $@`). dsh re-spawns
`process.execPath` to run helpers, so `dsh web`'s browser handoff died with
`ld-linux-aarch64.so.1: unrecognized option '--input-type=module'`. `grun`
also word-splits its arguments (`source … $@` and `exec ld.so $@`, both
unquoted), so `dsh "two words"` arrived as two argv entries.

| Android difference | How it is handled instead |
|---|---|
| `process.execPath` is the glibc loader; helper re-spawns get loader flags and die | `configure_glibc_node` in `scripts/common.sh` points node's ELF **interpreter** at Termux's glibc loader, and the generated wrapper execs node **directly** — no grun, all arguments quoted |

Emitted by `write_dsh_wrapper` / `configure_glibc_node`, guarded by CI.

#### Two traps worth remembering

**Patch only the interpreter.** `patchelf --set-interpreter … --set-rpath …` in
one run produces a Node binary that **segfaults** (verified on node 22.20.0 with
patchelf 0.19.1/aarch64; either option alone is fine). No rpath is needed —
Termux's glibc loader already searches its own lib dir. CI rejects a reintroduced
`--set-rpath`.

**Never patch in place.** A running dsh has the binary `mmap`'d; rewriting those
pages under it raises SIGBUS/SIGSEGV and kills the live process — an in-place
`grun -c` killed a running `dsh web` during development. `configure_glibc_node`
does copy → patch → verify the copy runs → atomic `mv`, so running processes keep
their old inode and a bad patch can never replace a working node.

### Fix 3: browser handoff

`process.platform === "linux"` makes the `open` package run its bundled
freedesktop `xdg-open`, which exits 3 (`no method available`) on Android:
xdg-open walks `x-www-browser`/`firefox`/`lynx`/`w3m`…, finds none, and dsh
only awaits the spawn, so nothing is reported and nothing appears.

| Android difference | How it is handled instead |
|---|---|
| `open` finds no browser on Android | the wrapper points `BROWSER` at `work/dsh-termux-open`, an Android-intent opener emitted beside it. `xdg-open` reads `$BROWSER` before any desktop probe, and dsh's `native-path-opener` reads it directly, so one variable covers both |

Emitted by `write_dsh_opener`, guarded by CI. Nothing extra to install: both
openers (`termux-open-url`, `termux-open`) ship in `termux-tools` (an
Essential Termux package); Termux:API is not required.

#### Why the opener dispatches

Those two `$BROWSER` call sites are handed different things: `dsh web` passes an
http(s) URL (→ `termux-open-url`, i.e. `am start -a VIEW -d <url>`), while
`host.openPath` passes a **file path** for `.html`/`.htm`/`.xhtml`/`.svg`
(→ `termux-open`, because `am start -d <bare path>` cannot resolve an Intent and
only `TermuxOpenReceiver` builds the `content://` URI a local file needs).
Pointing `$BROWSER` straight at `termux-open-url` would fix the web handoff and
break HTML/SVG file opens, which already worked through Termux's own `xdg-open`.

**Keep Termux in the foreground when you start `dsh web`.** Android 10+ blocks
activity launches from background apps, so if you switch away first the intent
is dropped silently and `am` still exits 0. Export your own `BROWSER` to
override the choice, or pass `dsh web --no-open` to skip the handoff and just
use the printed URL.