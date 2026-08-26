# dsh-termux

Run [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`) on Termux (Android), no root required.

[English](README.md) | [中文](README.zh-CN.md)

## What this is

`dsh-termux` is a set of install & maintenance scripts that let `dsh` run inside Termux. It installs the official Node.js **linux-arm64** binary on Termux's glibc runtime, so dsh itself never needs rebuilding: npm resolves the linux-arm64 prebuilt native modules directly. A handful of small fixes adapt dsh to Android — the full list is the table below; the details live in [PATCHES.md](PATCHES.md).

## Fixes & adaptations for Termux

The fixes & adaptations this project makes so `dsh` runs on Termux, one line each. Details in [PATCHES.md](PATCHES.md).

| Fixes / adapts | One line | Detail |
|---|---|---|
| Session saves & the write tool fail `EACCES: link` | SELinux forbids hard links in app-private storage; patches fall back to `rename()` | [Patch 1](PATCHES.md#patch-1-hard-link-eacces) |
| `dsh web` handoff dies; arguments get word-split | `process.execPath` was the glibc loader; the launcher now execs node directly | [Fix 2](PATCHES.md#fix-2-direct-exec) |
| `dsh web` finds no browser on Android | `$BROWSER` points at an Android-intent opener | [Fix 3](PATCHES.md#fix-3-browser-handoff) |
| Improved dsh update experience | the wrapper owns `dsh update` and hands over to the bundled updater | [Fix 4](PATCHES.md#fix-4-update-shortcut) |

## Status and limitations

This is a small hobby project:

**How far testing goes**: the author uses dsh-termux daily on one arm64 phone, where install, update, both patches and `dsh web` all work. CI applies the patches to the newest npm release and boot-smokes a fresh install on Linux at every push — but no automated step ever walks a real Termux install, and the prebuilt releases plus `install.sh` have not been tried on a second device.

**Known weak spots**: upstream dsh moves fast, and a new release can change the files the patches target and break them (the updater then stops with an error instead of leaving you a broken install). Outside the patched code paths, Android can still surface problems this project has never seen.

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
`dsh-<bundled dsh version>-<project VERSION>`, e.g. `dsh-0.1.1-rc.2-1.0.1`):

```sh
DSH_RELEASE=dsh-0.1.1-rc.2-1.0.1 curl -fsSL https://github.com/ErEbusE/dsh-termux/releases/latest/download/install.sh | bash -s -- -y
```

Each release bundles the dsh `latest` snapshot at release time — the exact
version is shown in its release tag. Keep current later with the bundled
updater (see [Updating dsh](#updating-dsh)).

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

`dsh web` prints `http://127.0.0.1:3080` and opens it in your phone's browser
([Fix 3](PATCHES.md#fix-3-browser-handoff) in PATCHES.md).

> Installation completes without an API key; configure it later per the official dsh docs when you actually use `dsh` (config lives in `~/.dsh/`, overridable via environment).

### What the installer changes

| Item | Location |
|---|---|
| Node + dsh + patched deps | `$HOME/.local/opt/dsh-termux-runtime/` |
| `dsh` symlink | `$HOME/.local/bin/dsh` |
| PATH injection (tagged `# dsh-termux`) | end of `~/.bashrc` |

## Usage

```sh
dsh --version                  # show version
dsh web --port 3080            # start the web UI
dsh update -t next -y          # update dsh — see Updating dsh below
```

The `dsh` command behaves like the official CLI; see the upstream docs for full usage. Keep Termux in the foreground when starting `dsh web` — Android 10+ silently drops activity launches from background apps.

## Updating dsh

Upstream dsh moves fast. Updating to the npm `next` tag:

```sh
dsh update -t next -y
```

This is **not an upstream dsh feature**: upstream has only `web` and `plugin` as top-level subcommands, so the Termux wrapper generated by this project may safely own `update` as its first argument — it hands the rest of the argv to the bundled updater below (a missing updater fails with an explicit message). Every other invocation reaches dsh untouched.

Under the hood this runs `update-dsh.sh` — for example, the same command an Option B checkout would use:

```sh
bash scripts/update-dsh.sh -t next -y
```

Option A (release) users who have not yet updated past 1.1.0 — use the updater bundled at install time:

```sh
bash ~/.local/opt/dsh-termux-runtime/scripts/update-dsh.sh -t next -y
```

Once you are on 1.1.0 or newer, this can be replaced by the `dsh update` above; from then on the shortcut keeps itself up to date.

| Flag | Effect |
|---|---|
| `-t, --tag TAG` | install a dist-tag directly (e.g. `next`), no version menu |
| `-v, --version VER` | install an exact version directly (e.g. `0.1.1-rc.2`), no version menu |
| `-y, --yes` | auto-accept every prompt |
| (no `-t`/`-v`) | interactive version menu, Enter defaults to `latest` |

The updater installs the chosen version, re-applies and verifies the patches, then rewrites the `dsh` wrapper. If a new version changed the patched files so the patches no longer apply, it **fails loudly and stops** (it will never silently leave you on a broken install) — that means the patches need regenerating, see [PATCHES.md](PATCHES.md).

> The updater does **not** restart a running `dsh web`. Run `dsh web --port 3080` yourself after updating to pick up the new version.

## FAQ

**`dsh web` doesn't open the browser?**
Most common cause: Termux was in the background when you started `dsh web` — Android 10+ silently drops activity launches from background apps. Keep Termux in the foreground, or open the printed URL manually. Background details: [Fix 3](PATCHES.md#fix-3-browser-handoff).

**"Patch does not apply / version drift" during an update?**
A newly published dsh version changed the patched files. This is the intended safety stop — dsh stays installed but unpatched, so session saves and the write tool may fail with `EACCES` on Android. Please file an issue or regenerate the patches per [PATCHES.md](PATCHES.md).

**Where is my data?**
dsh's own data lives in `~/.dsh/` (upstream default); this project's runtime lives in `~/.local/opt/dsh-termux-runtime/`.

**How do I uninstall?**
1. Edit `~/.bashrc` and remove the line tagged `# dsh-termux`;
2. `rm ~/.local/bin/dsh`;
3. `rm -rf ~/.local/opt/dsh-termux-runtime` (and `~/.dsh` if you don't need dsh's data — double-check before deleting that one).

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
├─ PATCHES.md                fixes & adaptations detail (patches + environment fixes)
└─ README.md / README.zh-CN.md
```

> Runtime artifacts (`node/`, `work/`, `downloads/`) are created under `~/.local/opt/dsh-termux-runtime`, outside this repository (ignored via `.gitignore`).

## Contributing

Issues and PRs are welcome.

- **Reporting problems**: include your device model / Android version, Termux version (`termux-info`), and the full output of the failing command;
- **Fixing patch drift**: when an upstream release breaks a patch, regenerate both `.patch` files against the new `lib/*.js` following [PATCHES.md](PATCHES.md), and note the exact dsh version in your PR;
- **New Termux adaptations**: add a section to [PATCHES.md](PATCHES.md) and one row to the fixes table at the top of this README;
- **Code changes**: keep `bash -n` clean for script edits and test on a real Termux device where possible; changes to the patch logic (`scripts/patch-lib.sh`) are covered by the CI patch check; the `dsh` wrapper / `$BROWSER` opener generation lives only in `scripts/common.sh`; `build/install.sh` sources that same file out of the release tarball, and CI verifies install.sh has no duplicated copy of it;
- **CI**: every push / PR verifies the patches apply cleanly to the npm latest release plus a fresh-install boot smoke;
- **Releases**: the project version lives in `VERSION` (X.Y.Z) and a release tag is `dsh-<bundled dsh version>-<VERSION>`. A release publishes automatically when a version change is pushed to `main`; separately, when only upstream dsh moved — no project change, hence no push — the author manually triggers a release, so fresh Option A installs get the newest dsh straight from the release instead of updating afterwards. If neither `VERSION` nor the bundled dsh version changed relative to the last release, the run exits early without publishing; an already-existing tag fails the run.

## License

[MIT](LICENSE)