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
| 4 | updating needs a repo checkout or a long script path | the wrapper adds a `dsh update` shortcut to the bundled updater | [Fix 4](#fix-4-update-shortcut) |
| 5 | sandboxed bash cannot write `$TMPDIR` (workspace-write) | the Landlock dialect omits `os.tmpdir()` from its grants; the patch adds it | [Patch 5](#patch-5-landlock-tmpdir) |

---

## Part I — Patches (edit dsh's npm lib files)

### Adding a patch: the one registry

`DSH_PATCH_SET` in `scripts/patch-lib.sh` is the **single registry** — one
entry `<patch file>:<rel target>:<marker>` drives every consumer, so adding a
patch needs no edit anywhere else in the machinery:

| Consumer | How it picks the set up |
|---|---|
| `scripts/03-apply-patches.sh` (setup pipeline) | `dsh_apply_patch_set` iterates the registry |
| `scripts/update-dsh.sh` (updater) | same call — re-applies and verifies on update |
| `build/build-runtime.sh` (release build) | same call — patches the shipped tree |
| `build/install.sh` | applies nothing (the tarball ships pre-patched); unaffected |
| CI `build.yml` | apply step calls `dsh_apply_patch_set`; the marker check derives its rel list from the registry |
| CI `release.yml` | tarball copies the whole `patches/` dir; the structure check derives its patch-file AND target-lib list from the registry |
| sandbox routes + `serve.sh` | derive expected patches/markers from the workspace registry (R3, R4, serve — R1 tests install wiring only, the tarball ships pre-patched) or the shipped one inside the artifact under test (R2, R5 — old and new formats both parse) |

The manual remainder is documentation and release bookkeeping: a section in
this file, a row in each README's fixes table, and a `VERSION` bump so a
release ships it. Everything executable reads the registry.

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

(The third patch — the Landlock tmpdir grant — has its own section:
[Patch 5](#patch-5-landlock-tmpdir). The full set with per-patch markers lives
in `DSH_PATCH_SET` in `scripts/patch-lib.sh`.)

#### Upstream anchors

The two hard-link patches' pre-image files are byte-identical across the
published dsh releases tested so far — `@deepseek-ai/dsh` `0.1.0-rc.7`,
`0.1.0-rc.8`, `0.1.1-rc.1` and `0.1.1-rc.2` (verified by hashing `lib/index.js`
from the npm tarballs) — so one patch file keeps applying across those releases.
For `dsh-sandbox-local/lib/index.js` (patch 5's target) there are two distinct
builds: one hash for `0.1.0-rc.7`/`0.1.0-rc.8` and another for
`0.1.1-rc.1`/`0.1.1-rc.2`; the patched hunk's surrounding context is identical
in both, so the patch applies cleanly across all four anyway. When
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
npm pack @deepseek-ai/dsh-sandbox-local@<version>
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

### Patch 5: Landlock tmpdir

**Symptom**: under `workspace-write`, every sandboxed bash command that needs
a temp area fails — `mktemp`, `mkstemp`, redirection to `$TMPDIR` — with
`Permission denied` plus the `[sandbox: file access denied under
workspace-write mode]` marker, while the write/edit tools can write `$TMPDIR`
just fine. On Termux the only escape is escalating to `danger-full-access`.

**Root cause**: three facts stack up.

1. The Landlock dialect hardcodes its writable grants:
   `landlockProfileArgs` (in `dsh-sandbox-local`) grants `readWrite =
   ['/dev/null', '/tmp', workspaceRoot]` — `os.tmpdir()` is **not** in the
   list. Termux sets `TMPDIR=/data/data/com.termux/files/usr/tmp`, a *real
   directory distinct from `/tmp`*, so it is denied.
2. The shared `writableRoots` helper (`dsh-sandbox`), which the in-process fs
   fence **and** the macOS Seatbelt dialect both use, *does* include
   `tmpdir()` — that is why the write tool succeeds where bash fails. The
   upstream docstring of `writableRoots` itself says omitting `tmpdir()`
   "would deny what the mode promises"; the Landlock dialect simply predates
   that helper and was never aligned (the bwrap dialect has the same gap, hid
   by its private `--tmpfs /tmp` mount).
3. On this device the granted `/tmp` is a dead grant: a real directory owned
   by `shell:shell`, mode 771 — the app uid cannot write there, so the OS
   denies what Landlock allowed.

On desktop Linux the gap is invisible (`TMPDIR` unset → `os.tmpdir() ===
'/tmp'`), which is why upstream never saw it; Termux is a "Linux with
`TMPDIR ≠ /tmp`" deployment.

**The patch** adds `tmpdir()` to the grant list — one line plus a marker
comment (`dsh-termux-landlock-tmpdir`) inside `landlockProfileArgs`:

```js
if (policy.mode === "workspace-write") readWrite.push("/tmp", tmpdir(), policy.workspaceRoot);
```

**Why this is not a security widening**:

- the grant list is computed in the **harness process** (its own `tmpdir()`),
  before the child exists; a sandboxed `export TMPDIR=/etc` changes only the
  child's env, never the already-installed ruleset;
- Landlock rules bind to **inodes** at exec time (`open(path, O_PATH)` →
  `PATH_BENEATH`) and are inherited immutably across `execve` — no process in
  the tree can append rules afterwards;
- symlink/hardlink smuggling is still denied (Landlock evaluates resolved
  paths; `REFER` needs write access at both ends; and SELinux already forbids
  hard links in app-private storage — see patch 1);
- the fs fence and the Seatbelt dialect grant exactly this `tmpdir()` today —
  the patch brings the Landlock dialect up to the mode's documented contract,
  it does not open a boundary the other dialects keep closed.

Verified experimentally (landlock-run launcher driven directly): with the
stock grants a confined `sh -c 'echo x > "$TMPDIR/f"'` fails; adding
`--rw $TMPDIR` makes it succeed; `/etc` writes stay denied; a nonexistent
grant root fails closed with exit 125 and an explicit `landlock-run:` line
(the launcher's own philosophy — it never silently narrows a grant).

**Notes**:

- applies only to sandboxed child processes; the harness's own temp dirs
  (`dsh-spill-*` etc.) are unaffected. A **restart of `dsh web`** is required
  to load the patched bundle (JS-file patching carries none of the in-place
  patchelf risks of Fix 2);
- if a user starts dsh with a bogus `TMPDIR` (nonexistent path), confined
  commands fail at launcher start (exit 125, loud) instead of running with an
  unwritable temp — consistent with the launcher's fail-closed design;
- upstream fix tracked for the long term: the Landlock (and bwrap) dialects
  should derive their temp grants from the shared `writableRoots` helper.

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

### Fix 4: update shortcut

Upstream dsh has **no** `update` subcommand or `--update` option — its top level
is only the `web` and `plugin` subcommands plus `--profile`/`--patch`/`--dump-*`
flags (see upstream `apps/cli/src/args.ts`), so bare `dsh update` always died
with `error: --profile <name> is required`. The generated wrapper may therefore
safely own that first argument:

```sh
dsh update -t next -y
# exactly: bash ~/.local/opt/dsh-termux-runtime/scripts/update-dsh.sh -t next -y
```

| Android difference | How it is handled instead |
|---|---|
| Option A installs have no repo checkout; the updater sits deep under `~/.local/opt/dsh-termux-runtime/scripts/` | `write_dsh_wrapper` takes an optional updater path (4th argument) and bakes an intercept into the wrapper: when `$1` is exactly `update`, it shifts and `exec bash <updater> "$@"`; anything else reaches dsh verbatim |

Design notes:

- **Only `$1` is inspected.** The launcher passes everything after its own flags
  through to the booted app (`allowUnknownOption` + `passThroughOptions`), so
  inner arguments such as `--profile tui update ...` still reach that app;
- **the branch inherits the wrapper's environment** (`unset LD_PRELOAD`, glibc
  bin dir first) — the same one node gets;
- **a missing updater fails explicitly** (`exit 127`, pointing at reinstalling
  the runtime or running `scripts/update-dsh.sh` directly) instead of dsh's
  misleading "--profile required" error;
- **graceful degradation**: callers without an updater path get no branch
  emitted, so three-argument invocations behave byte-for-byte as before, and an
  install run by an OLD generator against a NEW caller ignores the surplus
  positional argument harmlessly (verified against the R1 baseline tarball);
- if a future upstream release ever adds its own `dsh update`, this
  interception shadows it — drop the fourth argument (regenerate the wrapper)
  before reporting an upstream bug.

Emitted by `write_dsh_wrapper` when given the optional updater path — all three
emitters pass it (`04-run-web.sh`, `update-dsh.sh`, `build/install.sh`). Not an
environment fix strictly needed to *run* dsh: it is convenience built on the
same single-source wrapper. Guarded by CI.