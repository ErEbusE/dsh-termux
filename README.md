# dsh-termux

Run [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`) on Termux (Android), no root required.

[English](README.md) | [中文](README.zh-CN.md)

## Why this approach

The usual ways to run a glibc Node app on Android are recompiling everything against Termux's own (bionic) Node, or a proot/glibc chroot. Recompiling forks dsh's entire native dependency chain into a second build you must maintain forever; a chroot adds a translation layer whose file semantics and activity launches still do not match Android's rules. dsh-termux instead ships the **official** Node.js linux-arm64 binary — the exact build npm's prebuilt modules were compiled for — on Termux's own glibc runtime, so upstream dsh and its dependencies run unmodified and nothing is ever compiled on-device. Only a small patch set adapts the Android-specific problems that remain (SELinux link policy, intent-based browser handoff, Landlock tmpdir grants, cross-site session cookies), and the bundled updater re-verifies it on every run; the complete index is [PATCHES.md](PATCHES.md).

## Installation

> Only **arm64** devices are supported (nearly all modern Android phones are arm64).

### Option A: install from a GitHub release

```sh
pkg install glibc-repo
pkg install glibc glibc-runner
curl -fsSL https://github.com/ErEbusE/dsh-termux/releases/latest/download/install.sh | bash -s -- -y
```

The installer downloads the newest runtime release, unpacks it and wires up the `dsh` command. Each release bundles the dsh `latest` snapshot taken at release time — the exact version is in the release tag. To pin one release, prefix `DSH_RELEASE=<tag>` (tags are `dsh-<bundled dsh>-<project version>`, e.g. `dsh-0.1.1-rc.2-1.0.1`).

### Option B: clone this repo and install locally

```sh
pkg install glibc-repo
pkg install glibc glibc-runner
git clone https://github.com/ErEbusE/dsh-termux.git
cd dsh-termux
bash scripts/00-setup.sh        # add -y to auto-accept every prompt
```

Option B resolves dsh from npm at install time (whatever is published right then); Option A ships the release-time snapshot. Both end up with the same layout and the same bundled updater.

### Verify

```sh
dsh --version    # prints the installed version (tracks npm, so it changes)
dsh web --port 3080
```

`dsh web` prints `http://127.0.0.1:3080` and opens it in your phone's browser — keep Termux in the **foreground** while starting it (Android 10+ silently drops background activity launches); the `dsh` command behaves exactly like the official upstream CLI, plus the `update` command added by this project (see [Updating](#updating)).

## Updating

```sh
dsh update            # interactive version menu (Enter defaults to latest)
dsh update -t next -y # straight to the npm `next` dist-tag, prompts auto-accepted
```

Updating re-applies the Android patches, which needs `git` on the device (`pkg install git`).

| Flag | Effect |
|---|---|
| `-t, --tag TAG` | install a dist-tag directly (e.g. `next`), no version menu |
| `-v, --version VER` | install an exact version directly (e.g. `0.1.1-rc.2`), no version menu |
| `-y, --yes` | auto-accept every prompt |
| `--self` | first refresh the updater + patch set to the latest project release, then continue into the dsh update |
| (no `-t`/`-v`) | interactive version menu, Enter defaults to `latest` |

`dsh update` never restarts a running `dsh web` — start it again yourself afterwards.

## What installation changes — and how to uninstall

Installation touches exactly three places: it unpacks the self-contained runtime (Node + patched dsh + updater) into `~/.local/opt/dsh-termux-runtime/`, symlinks the `dsh` command at `~/.local/bin/dsh`, and appends one PATH line tagged `# dsh-termux` at the end of `~/.bashrc`. dsh's own data (config, sessions) is separate, under `~/.dsh/`.

Uninstall — remove the files:

```sh
rm ~/.local/bin/dsh
rm -rf ~/.local/opt/dsh-termux-runtime
rm -rf ~/.dsh    # dsh's data (config/sessions); only if you don't need it — double-check first
```

The line tagged `# dsh-termux` in `~/.bashrc` must be deleted manually.

## FAQ

**`dsh web` doesn't open the browser?**
Most common cause: Termux was in the background — Android 10+ silently drops activity launches from background apps. Keep Termux in the foreground, or open the printed URL manually. Background details: [Fix 3](PATCHES.md#fix-3-browser-handoff).

**Update stopped with "Patch does not apply / version drift"?**
A newly published dsh changed the patched files. This is the intended safety stop — dsh stays installed but unpatched, so session saves and the write tool may fail with `EACCES` on Android. File an [issue](https://github.com/ErEbusE/dsh-termux/issues) or regenerate the patches per [PATCHES.md](PATCHES.md).

**`dsh update` unknown on a long-overdue install?**
Runtimes from releases before 1.1.0 have no wrapper shortcut: run the bundled updater directly — `bash ~/.local/opt/dsh-termux-runtime/scripts/update-dsh.sh -t next -y`. From 1.1.0+ the `dsh update` shortcut keeps itself current; runtimes from before 1.2.1 also lack the automatic patch-set refresh (updates proceed on the old set, with a notice), and a fresh Option A install brings them fully current.

**Where is my data?**
dsh data lives in `~/.dsh/` (upstream default); this project's runtime in `~/.local/opt/dsh-termux-runtime/`.

## Contributing

Issues and PRs are welcome. The contributor workflow — testing gates (sandbox + on-device), CI, releases, and the update mechanism internals — is in [CONTRIBUTING.md](CONTRIBUTING.md); how every Android fix works and how to regenerate drifted patches is in [PATCHES.md](PATCHES.md). If you develop with AI agents, [AGENTS.md](AGENTS.md) is the repo protocol they follow.

## Project layout

```
dsh-termux/
├─ patches/                  Android patches (over dsh's compiled npm lib files)
├─ scripts/                  install/update pipeline (runs on Termux)
│   ├─ 00-setup.sh           Option B entry: env config, drives 01→04
│   ├─ 01-setup-glibc-node.sh   fetch Node, point its ELF interpreter at glibc
│   ├─ 02-install-dsh.sh / 03-apply-patches.sh / 04-run-web.sh
│   ├─ update-dsh.sh         updater: version switch + re-patch + wrapper rewrite
│   └─ common.sh / patch-lib.sh  shared helpers (wrapper & $BROWSER generators,
│                                patch registry; reused by CI)
├─ build/                    CI / offline build tooling (arm64 Linux)
│   ├─ build-runtime.sh      builds the release tarball (node + dsh + patches + verify)
│   └─ install.sh            self-contained installer (release asset + inside the tarball)
├─ .github/workflows/        CI: static gate (verify) + npm patch canary (patch-check)
│                            + stable releases + source-built pre-releases
├─ .test-install/            sandboxed test harness: six routes + serve.sh checklist
├─ VERSION / NODE_VERSION    project release number (X.Y.Z; tags are dsh-<dsh>-<VERSION>) / Node version the runtime is built with
├─ README.md / README.zh-CN.md   user docs: install / update / uninstall
├─ PATCHES.md                single index of all fixes & adaptations + patch mechanics
├─ CONTRIBUTING.md           contributor workflow: testing gates, CI, releases
└─ AGENTS.md                 AI-agent protocol (testing truth-claims, sandbox boundary)
```

> Runtime artifacts (`node/`, `work/`, `downloads/`) are built outside this repository, under `~/.local/opt/dsh-termux-runtime/`.

## Availability statement

Small hobby project. The author runs it daily on one arm64 phone, where install, update, the patches and `dsh web` all work. CI applies the patch set to the newest npm dsh and boot-smokes a fresh install on Linux, but no automated step ever walks a real Termux install, and the prebuilt releases have not been tried on a second device. Upstream dsh moves fast: a new release can change the patched files — the updater then stops with an error instead of breaking your install — and outside the patched paths Android can still surface problems this project has never seen. Back up anything important, keep expectations modest, and [report what breaks](https://github.com/ErEbusE/dsh-termux/issues).

## License

[MIT](LICENSE)
