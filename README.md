# dsh-termux

Run [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`) on Termux (Android), no root required.

[中文说明](README.zh-CN.md)

## What this is

`dsh-termux` is a set of install & maintenance scripts that let `dsh` run inside Termux. Once installed, you can use `dsh` on your phone just like on a desktop: CLI conversations, the `dsh web` browser UI, headless task runs.

### How it differs from the common Termux setups

The usual way to run `dsh` on Termux is to use Termux's own Node under Bionic libc and fix the native-module fallout one by one. This project takes a different route: it runs the official Node through a glibc runtime.

| | Common Bionic approach | This project |
|---|---|---|
| Runtime | Termux's own Node (Bionic libc) | Official Node linux-arm64 + `grun` (glibc) |
| Native modules | Handled one by one: koffi needs a `statx` workaround, sharp / node-pty lack Android binaries or must be rebuilt under Bionic | npm resolves the linux-arm64 prebuilt binaries directly — **no compilation** |
| Patches | Usually several, drifting with upstream | Only 2 (see below), byte-anchored and re-verified by CI on every run |
| Dependencies | Depends on the approach | `glibc-repo` + `glibc` + `glibc-runner` |
| Fidelity to upstream dsh | High | High (installed from npm, patched, not forked) |

Under glibc, `process.platform` reports `linux`, so npm automatically resolves the linux-arm64 prebuilt native modules (koffi, node-pty, sharp) — the most annoying part simply disappears.

Two small patches remain, both for the same Android filesystem quirk: SELinux forbids hard links in app-private storage, while dsh's session store and write tool publish files with `link()`, which fails with `EACCES` on Android. The patches fall back to `rename()` when the platform denies linking. Details in [PATCHES.md](PATCHES.md).

## ⚠ Testing status & known risks (please read)

This is a **personally maintained, small project**. Set expectations accordingly:

- Maintained mostly by one person, and fully tested **on the maintainer's own device only**;
- The CI in this repo verifies that the patches apply cleanly to the latest npm release and that a fresh install boots on a **standard Linux host** — it does **not** exercise a real Termux installation;
- Prebuilt releases, `install.sh`, and multiple devices / Android versions are **not thoroughly tested**;
- `dsh` itself iterates quickly; new upstream versions may introduce patch drift or other issues this project hasn't seen yet.

In short: **hidden issues are possible**. By using it you accept the risk; back up anything important first.

To be fair about the known-good part: installation, updating, the 2 patches and the `dsh web` boot are all verified on the maintainer's device, and CI re-runs the patch check + boot smoke on every push/PR.

## Installation

> Only **arm64** devices are supported (nearly all modern Android phones are arm64).

### 1. Install dependencies

```sh
pkg install glibc-repo
pkg install glibc glibc-runner
```

### 2. Clone and run the installer

```sh
git clone https://github.com/ErEbusE/dsh-termux.git
cd dsh-termux
bash scripts/00-setup.sh
```

The script walks you through: downloading Node linux-arm64 → installing dsh from npm → applying the patches → starting web. Add `-y` to auto-accept every prompt:

```sh
bash scripts/00-setup.sh -y
```

> Installation completes without an API key; configure it later per the official dsh docs when you actually use `dsh` (config lives in `~/.dsh/`, overridable via environment).

### 3. Verify

```sh
dsh --version    # prints the installed version (tracks npm, so it changes)
dsh web --port 3080
```

`dsh web` prints `http://127.0.0.1:3080` — open it in your phone's browser for the web UI.

### What the installer changes

| Item | Location |
|---|---|
| Node + dsh + patched deps | `$HOME/.local/opt/dsh-termux-runtime/` |
| `dsh` wrapper (grun forwarder) | `$HOME/.local/opt/dsh-termux-runtime/work/dsh` |
| `dsh` symlink | `$HOME/.local/bin/dsh` |
| PATH injection (tagged `# dsh-termux`) | end of `~/.bashrc` |

## Usage

```sh
dsh --version                  # show version
dsh web --port 3080            # start the web UI
dsh --profile headless "..."   # run one task headlessly
```

The `dsh` command behaves like the official CLI; see the upstream docs for full usage.

### Updating dsh

dsh moves fast. Update to the npm `next` tag, auto-accepting everything:

```sh
bash scripts/update-dsh.sh -t next -y
```

| Flag | Effect |
|---|---|
| `-t, --tag TAG` | install a dist-tag directly (e.g. `next`), no version menu |
| `-v, --version VER` | install an exact version directly (e.g. `0.1.1-rc.1`), no version menu |
| `-y, --yes` | auto-accept every prompt |
| (no `-t`/`-v`) | interactive version menu, Enter defaults to `latest` |

The updater installs the chosen version, re-applies and verifies the 2 patches, then rewrites the `dsh` wrapper. If a new version changed the patched files so the patches no longer apply, it **fails loudly and stops** (it will never silently leave you on a broken install) — that means the patches need regenerating, see [PATCHES.md](PATCHES.md).

> The updater does **not** restart a running `dsh web`. Run `dsh web --port 3080` yourself after updating to pick up the new version.

## FAQ

**"Patch does not apply / version drift" during an update?**
A newly published dsh version changed the patched files. This is the intended safety stop — dsh stays installed but unpatched, so session saves and the write tool may fail with `EACCES` on Android. Please file an issue or regenerate the patches per PATCHES.md.

**Where is my data?**
dsh's own data lives in `~/.dsh/` (upstream default); this project's runtime lives in `~/.local/opt/dsh-termux-runtime/`.

**How do I uninstall?**
1. Edit `~/.bashrc` and remove the line tagged `# dsh-termux`;
2. `rm ~/.local/bin/dsh`;
3. `rm -rf ~/.local/opt/dsh-termux-runtime` (and `~/.dsh` if you don't need dsh's data — double-check before deleting that one).

## How it works (for the curious)

1. **glibc runtime**: the official Node.js linux-arm64 binary runs via Termux's `glibc-runner` (`grun`). Under glibc, `process.platform === "linux"`, so npm resolves the linux-arm64 prebuilt native modules directly — no source compilation.
2. **Only 2 patches**: both address the same Android platform behavior — SELinux forbids hard links in app-private storage. dsh's session store and write tool publish files with `link()`, which fails with `EACCES` on Android; the patches fall back to `rename()` when the platform denies linking. They target the compiled `lib/*.js` files inside the npm packages; purpose, anchors and regeneration are in [PATCHES.md](PATCHES.md).

## Repository layout

```
dsh-termux/
├─ patches/                  Android hard-link patches (npm lib files)
│   ├─ npm-dsh-session-persistence-jsonl-link-rename.patch
│   └─ npm-dsh-fs-local-link-rename.patch
├─ scripts/                  install/update pipeline (runs on Termux)
│   ├─ 00-setup.sh           entry point: env config, drives 01→04
│   ├─ 01-setup-glibc-node.sh
│   ├─ 02-install-dsh.sh
│   ├─ 03-apply-patches.sh
│   ├─ 04-run-web.sh         wrapper + PATH setup + web launch
│   ├─ update-dsh.sh         update to a chosen version + re-verify patches
│   ├─ common.sh / patch-lib.sh    shared helpers (patch logic reused by CI)
├─ build/                    CI / offline build tooling (arm64 Linux)
│   ├─ build-runtime.sh      fetch node + install dsh + patch + verify
│   └─ install.sh            self-contained installer inside release tarballs
├─ .github/workflows/        CI: verify patches (build.yml) + releases (release.yml)
├─ PATCHES.md                patch purpose, anchors, regeneration
└─ README.md / README.zh-CN.md
```

> Runtime artifacts (`node/`, `work/`, `downloads/`) are created under `~/.local/opt/dsh-termux-runtime`, outside this repository (ignored via `.gitignore`).

## Maintainer docs (regular users can skip)

- **CI**: on every push/PR the two patches are applied to the npm latest release and a fresh install + `dsh --version` + `dsh web` HTTP-200 smoke runs on a standard Linux host; `release.yml` builds release artifacts on an arm64 runner (manual dispatch or a `v*` tag push).
- **Patch maintenance**: regeneration flow in [PATCHES.md](PATCHES.md).
- **Relationship to upstream**: this repo does not fork `deepseek-ai/deepseek-harness` — dsh is installed from npm, and the 2 patches are the only local delta.

## Problems?

Please file an [issue](https://github.com/ErEbusE/dsh-termux/issues) with: device model / Android version, Termux version (`termux-info`), and the full output of the failing command.

## License

[MIT](LICENSE)
