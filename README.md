# dsh-termux

Run [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`) on Termux (Android), no root required.

[English](README.md) | [中文](README.zh-CN.md)

## What this is

`dsh-termux` is a set of install & maintenance scripts that let `dsh` run inside Termux. Once installed, you can use `dsh` on your phone just like on a desktop: CLI conversations, the `dsh web` browser UI, headless task runs.

Node runs on a glibc runtime from [glibc-runner](https://github.com/termux-pacman/glibc-packages), but the launcher execs the Node binary **directly** rather than through `grun`'s `ld.so <node>` indirection — through that indirection `process.execPath` becomes the dynamic loader instead of node, which breaks every dsh helper that re-spawns itself (`dsh web`'s browser handoff most visibly) and word-splits arguments. Details in [Browser handoff](#browser-handoff-dsh-web).

### How it differs from the common Termux setups

The usual way to run `dsh` on Termux is to use Termux's own Node under Bionic libc and fix the native-module fallout one by one. This project takes a different route: it runs the official Node through a glibc runtime.

| Runtime | Termux's own Node (Bionic libc) | Official Node linux-arm64 + Termux glibc runtime, exec'd directly (no `ld.so` indirection) |
| Native modules | Handled one by one: koffi needs a `statx` workaround, sharp / node-pty lack Android binaries or must be rebuilt under Bionic | npm resolves the linux-arm64 prebuilt binaries directly — **no compilation** |
| Patches | Usually several, drifting with upstream | Only 2 (see below), byte-anchored and re-verified by CI on every run |
| Dependencies | Depends on the approach | `glibc-repo` + `glibc` + `glibc-runner` |
| Sandbox | The official Landlock sandbox backend won't run: either skip sandboxing entirely (full access everywhere) or build one on Termux with proot — but proot makes everything outside the workdir unreadable, which clashes with `workspace-write`'s "workspace writable, rest readable" semantics and is awkward in practice | Kernel Landlock works natively, so the official sandbox backend runs as-is with full `workspace-write` semantics |

One more Android difference is handled without a patch: the `dsh web` browser handoff — see [Browser handoff](#browser-handoff-dsh-web).

Under glibc, `process.platform` reports `linux`, so npm automatically resolves the linux-arm64 prebuilt native modules (koffi, node-pty, sharp) — the most annoying part simply disappears. dsh itself is installed from npm's official releases, never rebuilt from source; only 2 small patches remain, for an Android filesystem quirk: SELinux forbids hard links in app-private storage, while dsh's session store and write tool publish files with `link()`, which fails with `EACCES` on Android. The patches fall back to `rename()` when the platform denies linking; details in [PATCHES.md](PATCHES.md).

## Status and limitations

This is a small hobby project, and here is honestly where it stands:

**How far testing goes**: the author uses dsh-termux daily on one arm64 phone, where install, update, both patches and `dsh web` all work. CI applies the patches to the newest npm release and boot-smokes a fresh install on Linux at every push — but no automated step ever walks a real Termux install, and the prebuilt releases plus `install.sh` have not been tried on a second device.

**Known weak spots**: upstream dsh moves fast, and a new release can change the files the patches target and break them (the updater then stops with an error instead of leaving you a broken install). Outside the two patched code paths, Android can still surface problems this project has never seen.

So keep expectations modest: back up anything important before using it, and please report what breaks in the [Issues](https://github.com/ErEbusE/dsh-termux/issues) tab.

## Installation

> Only **arm64** devices are supported (nearly all modern Android phones are arm64).

### Option A: one-liner (installs the latest prebuilt release)

```sh
pkg install glibc-repo
pkg install glibc glibc-runner
curl -fsSL https://github.com/ErEbusE/dsh-termux/releases/latest/download/install.sh | bash -s -- -y
```

The installer downloads the newest runtime release automatically, unpacks it
and wires up the `dsh` command. To pin a specific release (tags are
`dsh-<bundled dsh version>-<project VERSION>`, e.g. `dsh-0.1.1-rc.1-1.0.0`):

```sh
DSH_RELEASE=dsh-0.1.1-rc.1-1.0.0 curl -fsSL https://github.com/ErEbusE/dsh-termux/releases/latest/download/install.sh | bash -s -- -y
```

A release is a snapshot of the dsh version it bundles; keep current later with
the bundled updater (see [Updating dsh](#updating-dsh)).

### Option B: clone this repo and install fresh

```sh
pkg install glibc-repo
pkg install glibc glibc-runner
git clone https://github.com/ErEbusE/dsh-termux.git
cd dsh-termux
bash scripts/00-setup.sh        # add -y to auto-accept every prompt
```

The difference: Option B resolves dsh from npm at install time (whatever is
published right then), while Option A ships the release-time snapshot. Both
end up with the same layout and the same bundled updater.

### Verify

```sh
dsh --version    # prints the installed version (tracks npm, so it changes)
dsh web --port 3080
```

`dsh web` prints `http://127.0.0.1:3080` — open it in your phone's browser for the web UI.

> Installation completes without an API key; configure it later per the official dsh docs when you actually use `dsh` (config lives in `~/.dsh/`, overridable via environment).

### What the installer changes

| Item | Location |
|---|---|
| Node + dsh + patched deps | `$HOME/.local/opt/dsh-termux-runtime/` |
| `dsh` wrapper (direct Node exec) | `$HOME/.local/opt/dsh-termux-runtime/work/dsh` |
| `$BROWSER` opener (Android intents) | `$HOME/.local/opt/dsh-termux-runtime/work/dsh-termux-open` |
| `dsh` symlink | `$HOME/.local/bin/dsh` |
| PATH injection (tagged `# dsh-termux`) | end of `~/.bashrc` |
| Node ELF interpreter | pointed at Termux's glibc loader so the kernel can exec node directly |

## Usage

```sh
dsh --version                  # show version
dsh web --port 3080            # start the web UI
dsh --profile headless "..."   # run one task headlessly
```

The `dsh` command behaves like the official CLI; see the upstream docs for full usage.

### Browser handoff (`dsh web`)

`dsh web` opens the phone's default browser automatically. Two independent Termux problems used to break this; both are fixed without patching dsh.

**1. `process.execPath` was the glibc loader, not node.** dsh re-spawns itself (`spawn(process.execPath, …)`) to run the browser opener. `grun` launches a glibc binary as `ld.so <binary>`, so the program the kernel executed — and therefore `/proc/self/exe` and `process.execPath` — was `ld-linux-aarch64.so.1`; the spawn handed Node's flags to the loader, which rejected them:

```
web-app: could not open the default browser because
/data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1: unrecognized option '--input-type=module'
```

The opener child died before it could even `import('open')`. Fix: the install points Node's ELF interpreter at Termux's glibc loader (safely — copy, patch, verify, atomic rename; see [PATCHES.md](PATCHES.md) for the two traps), and the wrapper execs Node directly. That also fixes argument word-splitting — `grun` passed `$@` unquoted twice, so `dsh "two words"` arrived as two argv entries.

**2. The `open` package found no browser.** Under glibc Node `process.platform` is `linux`, so `open` prefers its own bundled freedesktop `xdg-open`, which on Android walks `x-www-browser`/`firefox`/`lynx`/`w3m`…, finds none, and exits 3 with `no method available` — while dsh only awaits the spawn, so nothing was reported and nothing appeared.

The wrapper points `$BROWSER` at `work/dsh-termux-open`, a small Android-intent opener written next to it. It dispatches because dsh hands `$BROWSER` two different things:

| dsh passes | opener uses | why |
|---|---|---|
| `http(s)://…` — the `dsh web` URL | `termux-open-url` | `am start -a android.intent.action.VIEW -d <url>` |
| a **file path** for `.html`/`.htm`/`.xhtml`/`.svg` | `termux-open` | `am start -d <bare path>` cannot resolve an Intent (exits 1); only `TermuxOpenReceiver` builds the `content://` URI a local file needs |

- Nothing extra to install: both openers ship in `termux-tools` (an Essential Termux package); Termux:API is not required.
- **Keep Termux in the foreground when you start `dsh web`.** Android 10+ blocks activity launches from background apps, so if you switch away first the intent is dropped silently and `am` still exits 0.
- Export your own `BROWSER` to override the choice, or pass `dsh web --no-open` to skip the handoff and just use the printed URL.

### Updating dsh

dsh moves fast. Update to the npm `next` tag, auto-accepting everything:

```sh
bash scripts/update-dsh.sh -t next -y
```

Option A (release) users don't have this repo checked out — use the updater
bundled at install time:

```sh
bash ~/.local/opt/dsh-termux-runtime/scripts/update-dsh.sh -t next -y
```

| Flag | Effect |
|---|---|
| `-t, --tag TAG` | install a dist-tag directly (e.g. `next`), no version menu |
| `-v, --version VER` | install an exact version directly (e.g. `0.1.1-rc.2`), no version menu |
| `-y, --yes` | auto-accept every prompt |
| (no `-t`/`-v`) | interactive version menu, Enter defaults to `latest` |

The updater installs the chosen version, re-applies and verifies the 2 patches, then rewrites the `dsh` wrapper. If a new version changed the patched files so the patches no longer apply, it **fails loudly and stops** (it will never silently leave you on a broken install) — that means the patches need regenerating, see [PATCHES.md](PATCHES.md).

> The updater does **not** restart a running `dsh web`. Run `dsh web --port 3080` yourself after updating to pick up the new version.

## FAQ

**`dsh web` doesn't open the browser?**
See [Browser handoff](#browser-handoff-dsh-web). Most common cause: Termux was in the background when you started `dsh web` — Android 10+ silently drops activity launches from background apps. Keep Termux in the foreground, or open the printed URL manually.

**"Patch does not apply / version drift" during an update?**
A newly published dsh version changed the patched files. This is the intended safety stop — dsh stays installed but unpatched, so session saves and the write tool may fail with `EACCES` on Android. Please file an issue or regenerate the patches per PATCHES.md.

**Where is my data?**
dsh's own data lives in `~/.dsh/` (upstream default); this project's runtime lives in `~/.local/opt/dsh-termux-runtime/`.

**How do I uninstall?**
1. Edit `~/.bashrc` and remove the line tagged `# dsh-termux`;
2. `rm ~/.local/bin/dsh`;
3. `rm -rf ~/.local/opt/dsh-termux-runtime` (and `~/.dsh` if you don't need dsh's data — double-check before deleting that one).

## Staying current with upstream

This project never builds dsh from source: every install or update pulls a specific version of `@deepseek-ai/dsh` from npm (`latest`, `next`, or an exact version), so official upstream releases are usable as soon as they publish. The local delta is just 2 patch files targeting compiled `lib/*.js` inside the npm packages; at the end of every install/update, the scripts apply those patches to the freshly installed files and verify them. If an upstream release changes those files and a patch no longer applies, the update stops with a clear error — regenerate the patches per [PATCHES.md](PATCHES.md) and you can keep following upstream.

## Repository layout

```
dsh-termux/
├─ patches/                  Android hard-link patches (npm lib files)
│   ├─ npm-dsh-session-persistence-jsonl-link-rename.patch
│   └─ npm-dsh-fs-local-link-rename.patch
├─ scripts/                  install/update pipeline (runs on Termux)
│   ├─ 00-setup.sh           entry point: env config, drives 01→04
│   ├─ 01-setup-glibc-node.sh   fetches Node and points its ELF interpreter at glibc
│   ├─ 02-install-dsh.sh
│   ├─ 03-apply-patches.sh
│   ├─ 04-run-web.sh         wrapper + PATH setup + web launch
│   ├─ update-dsh.sh         update to a chosen version + re-verify patches
│   ├─ common.sh / patch-lib.sh    shared helpers (wrapper generator + patch logic reused by CI)
├─ build/                    CI / offline build tooling (arm64 Linux)
│   ├─ build-runtime.sh      fetch node + install dsh + patch + verify
│   └─ install.sh            self-contained installer (release asset + inside the tarball)
├─ .github/workflows/        CI: verify patches + wrapper (build.yml) + releases (release.yml)
├─ VERSION                   project release number (X.Y.Z); tags are dsh-<dsh version>-<VERSION>
├─ PATCHES.md                patch purpose, anchors, regeneration
└─ README.md / README.zh-CN.md
```

> Runtime artifacts (`node/`, `work/`, `downloads/`) are created under `~/.local/opt/dsh-termux-runtime`, outside this repository (ignored via `.gitignore`).

## Contributing

Issues and PRs are welcome.

- **Reporting problems**: include your device model / Android version, Termux version (`termux-info`), and the full output of the failing command;
- **Fixing patch drift**: when an upstream release breaks a patch, regenerate both `.patch` files against the new `lib/*.js` following [PATCHES.md](PATCHES.md), and note the exact dsh version in your PR;
- **Code changes**: keep `bash -n` clean for script edits and test on a real Termux device where possible; changes to the patch logic (`scripts/patch-lib.sh`) are covered by the CI patch check; the `dsh` wrapper / `$BROWSER` opener text is mirrored between `scripts/common.sh` and `build/install.sh`, also guarded by CI;
- **CI**: every push / PR verifies the patches apply cleanly to the npm latest release plus a fresh-install boot smoke;
- **Releases**: the project version lives in `VERSION` (X.Y.Z) and a release tag is `dsh-<bundled dsh version>-<VERSION>`. A release is created on a push to `main` or a manual dispatch, after a cheap gate: if neither `VERSION` nor the resolvable dsh version changed since the last release, the run exits early without publishing. The exact tag already existing is a hard error (forgot to bump `VERSION`?); a `VERSION` no newer than the last one is just a warning — keeping `VERSION` while the bundled dsh version moved upstream is expected. Manual dispatch follows the same gate.

## License

[MIT](LICENSE)
