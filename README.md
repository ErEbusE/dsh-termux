# dsh-termux

Run [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`) on Termux (Android).

[中文说明](README.zh-CN.md)

## Approach

This project runs dsh on the official Node.js linux-arm64 binary (glibc), using Termux's [glibc-runner](https://github.com/termux-pacman/glibc-packages) glibc runtime.

Install points Node's ELF **interpreter** at Termux's glibc loader, and the generated `dsh` wrapper then execs Node **directly**. It deliberately does not launch Node through `grun`: `grun` runs `ld.so <node>`, which makes `process.execPath` the loader instead of node (breaking every dsh helper that re-spawns it) and word-splits arguments. See [Browser handoff](#browser-handoff-dsh-web).

Under glibc Node, `process.platform` reports `linux`, so npm resolves the linux-arm64 prebuilt native modules (koffi, node-pty, sharp) automatically. No source compilation is required.

Two patches remain. They address a platform-specific behavior of Android's SELinux policy, which denies hard-link creation in app-private storage. The dsh session store and the write tool publish files with `link()`; on Android this fails with `EACCES`. Both patches make them fall back to `rename()` when the platform denies linking.

One more Android difference is handled without a patch: the browser handoff. See [Browser handoff](#browser-handoff-dsh-web).

## Requirements

- Termux (arm64)
- glibc-repo, glibc, glibc-runner (`pkg install glibc-repo`, then `pkg install glibc glibc-runner`)

## Quick start (Termux)

```sh
git clone https://github.com/ErEbusE/dsh-termux.git
cd dsh-termux

bash scripts/00-setup.sh            # default values, asks before each step
bash scripts/00-setup.sh -y         # default values, fully non-interactive
bash scripts/00-setup.sh --interaction   # interactively configure env + asks
```

`00-setup.sh` drives the pipeline:

| Script | What it does |
|---|---|
| `00-setup.sh` | entry point; uses default env values unless `--interaction`; `-y` auto-accepts every prompt |
| `01-setup-glibc-node.sh` | verifies Termux + glibc components (installs if asked), fetches official Node linux-arm64, points its ELF interpreter at Termux's glibc loader |
| `02-install-dsh.sh` | `npm install @deepseek-ai/dsh --ignore-scripts` |
| `03-apply-patches.sh` | applies the Android hard-link patches |
| `04-run-web.sh` | writes the `dsh` wrapper (direct Node exec + `$BROWSER` handoff), links it onto PATH, appends `~/.bashrc` tag, starts web |

After setup, `dsh` behaves like the original CLI:

```sh
dsh --version                # 0.1.0-rc.7
dsh web --port 3080          # serve the browser UI
dsh --profile headless "..." # run one task
```

The wrapper lives at `$HOME/.local/opt/dsh-termux-runtime/work/dsh`. It execs the configured glibc Node directly and points `$BROWSER` at Termux's Android-intent opener. `04-run-web.sh` symlinks it into your bin dir (default `$HOME/.local/bin`) and prepends that dir to `PATH` in `~/.bashrc` (tagged `# dsh-termux`).

### Browser handoff (`dsh web`)

Two independent Termux problems broke this; both are fixed without patching dsh.

**1. `process.execPath` was the glibc loader, not node.** dsh re-spawns itself to run the opener:

```ts
spawn(process.execPath, ['--input-type=module', '--eval', BROWSER_OPENER_PROGRAM, '--', url], …)
```

`grun` launches a glibc binary as `ld.so <binary>`, so the program the kernel executed — and therefore `/proc/self/exe` and `process.execPath` — is `ld-linux-aarch64.so.1`. The spawn then handed Node's flags to the loader:

```
web-app: could not open the default browser because
/data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1: unrecognized option '--input-type=module'
```

The opener child died before it could even `import('open')`. Fix: `configure_glibc_node` sets Node's ELF interpreter to Termux's glibc loader, and the wrapper execs Node directly. That also fixes argument word-splitting — `grun` passes `$@` unquoted twice, so `dsh "two words"` used to arrive as two argv entries.

Two traps, both learned the hard way and both guarded in CI:

- **Only `--set-interpreter`.** Combining it with `--set-rpath` in one `patchelf` run yields a Node binary that **segfaults**. Either alone is fine, and no rpath is needed — Termux's glibc loader already searches its own lib dir.
- **Never patch in place.** A running dsh has the binary `mmap`'d; rewriting it raises SIGBUS/SIGSEGV and kills the live process. The install does copy → patch → verify the copy runs → atomic `mv`, so running processes keep their inode and a bad patch can never replace a working node.

**2. The `open` package found no browser.** `dsh web` hands its URL to the default browser through the `open` package. Under glibc Node `process.platform` is `linux`, so `open` prefers its own bundled freedesktop `xdg-open`. Android has no freedesktop desktop, so that script walks `x-www-browser`/`firefox`/`lynx`/`w3m`…, finds none, and exits 3 with `no method available`. dsh only waits for the spawn, so it reports nothing and no browser ever appears.

The generated `dsh` wrapper fixes this without patching dsh: it points `$BROWSER` at `work/dsh-termux-open`, a small Android-intent opener written next to it. `xdg-open` consults `$BROWSER` before any desktop probe, so the URL reaches the phone's default browser.

`$BROWSER` is read from two dsh call sites that need **different** intents, which is why the opener dispatches instead of hardcoding one tool:

| dsh passes | opener uses | why |
|---|---|---|
| `http(s)://…` — the `dsh web` URL | `termux-open-url` | `am start -a android.intent.action.VIEW -d <url>` |
| a **file path** for `.html`/`.htm`/`.xhtml`/`.svg` — `host.openPath` prefers a named browser for documents a browser renders | `termux-open` | `am start -d <bare path>` cannot resolve an Intent (exits 1); only `TermuxOpenReceiver` builds the `content://` URI a local file needs |

- Nothing extra to install: both openers ship in `termux-tools` (an Essential Termux package) and `am` in its `termux-am` dependency. Termux:API is not required.
- **Keep Termux in the foreground when you start `dsh web`.** Android 10+ blocks activity launches from background apps, so if you switch away first the intent is dropped silently and `am` still exits 0.
- Export your own `BROWSER` to override the choice, or pass `dsh web --no-open` to skip the handoff and just use the printed URL.

### Flags and modes

```sh
bash scripts/00-setup.sh                  # default values, asks before each step
bash scripts/00-setup.sh --interaction    # interactively configure env + asks
bash scripts/00-setup.sh -y               # default values, auto-accept all prompts
bash scripts/00-setup.sh --interaction -y # interactive env, auto-accept installs
```

Environment variables are validated on input: the runtime dir must be an absolute space-free path (npm and the ELF loader path dislike spaces), and the Node version must match dsh's engines (`^22.19.0 || >=24.0.0`).

### Updating dsh

`update-dsh.sh` reinstalls dsh from npm to a chosen version and re-verifies the
patches against the freshly installed libs:

```sh
bash scripts/update-dsh.sh                  # pick a version interactively
bash scripts/update-dsh.sh -y               # update to latest, auto-accept
bash scripts/update-dsh.sh -v 0.1.0-rc.8    # update to a specific version
bash scripts/update-dsh.sh -t next          # update to a dist-tag (e.g. next)
```

| Flag | Effect |
|---|---|
| `-v, --version VER` | install an exact version (overrides tag selection) |
| `-t, --tag TAG` | install an npm dist-tag (default `latest`) |
| `-y, --yes` | auto-accept every prompt |

The updater prints the available dist-tags, installs with `--ignore-scripts`,
then reverse-applies any prior patch and re-applies it so it is verified against
the installed version. If a patch no longer matches, it reports version drift
(see [PATCHES.md](PATCHES.md) to regenerate).

The updater does **not** manage a running web instance. Start or restart the
web UI yourself with `dsh web --port 3080` after updating, so the updater
stays free of side effects.

## Patches

| Patch | Problem solved |
|---|---|
| `npm-dsh-session-persistence-jsonl-link-rename.patch` | session save fails with `EACCES` on Android because the session store publishes files via `link()`; falls back to `rename()` when the platform denies linking |
| `npm-dsh-fs-local-link-rename.patch` | write tool fails with `EACCES` on Android because it publishes via `link()` in `createIfAbsent` mode; falls back to `rename()` on platform link denials |

See [PATCHES.md](PATCHES.md) for details, upstream anchors, and regeneration.

## Repository layout

```
patches/         # Android hard-link patches (npm lib files)
  npm-dsh-session-persistence-jsonl-link-rename.patch
  npm-dsh-fs-local-link-rename.patch
PATCHES.md       # per-patch purpose, anchors, regeneration flow
scripts/         # device-side install/update pipeline (runs on Termux)
  common.sh                # shared prompt/validation helpers + `dsh` wrapper generator
  00-setup.sh              # entry: env config + drives 01-04
  01-setup-glibc-node.sh
  02-install-dsh.sh
  03-apply-patches.sh
  04-run-web.sh            # wrapper + PATH setup + web launch
  update-dsh.sh           # reinstall to a chosen version + re-verify patches
build/           # CI/offline build tooling (runs on arm64 Linux)
  build-runtime.sh        # fetch node + install dsh + patch + verify (no interaction)
  install.sh              # self-contained installer shipped inside the release tarball
.github/workflows/  # CI: verify patches (build.yml) + produce releases (release.yml)
```

The runtime artifacts (`node/`, `work/`, `downloads/`) are created under `$DSH_RUNTIME_DIR` (default `$HOME/.local/opt/dsh-termux-runtime`) and are not part of this repository.

## CI

- **`.github/workflows/build.yml`** runs on every push/PR to verify the two patches apply cleanly to the published npm packages and that a fresh `npm install --ignore-scripts` + patch + boot smoke passes on a standard Linux host.
- **`.github/workflows/release.yml`** runs on a native arm64 runner (`ubuntu-24.04-arm`) and produces a distributable runtime. It calls `build/build-runtime.sh`, which fetches the linux-arm64 Node binary, installs dsh with `--ignore-scripts`, applies and verifies the patches, then runs a boot smoke test. It is triggered manually (`workflow_dispatch`, with an optional dsh npm spec and tag) or by pushing a `v*` tag.

## Release assets

A release attaches two files produced by `release.yml`:

- `dsh-termux-runtime-<tag>.tar.gz` — a tarball of `node/` (linux-arm64 Node) and `work/` (dsh + patched `node_modules`), built on an arm64 Linux host.
- `install.sh` — a self-contained installer that runs on the target Termux device.

To install a release on Termux:

```sh
pkg install glibc-repo && pkg install glibc glibc-runner
bash install.sh -y              # unpacks to $HOME/.local/opt/dsh-termux-runtime,
                                # configures Node, writes the wrapper + $BROWSER opener,
                                # symlinks ~/.local/bin/dsh, and appends PATH
                                # to ~/.bashrc (tagged # dsh-termux)
```

### Compatibility note

A release artifact is a **snapshot** built at release time and tested only against
the dsh version it bundles. Upstream dsh evolves and may change the patched libs;
if the patches drift, an older release may stop working. To track newer dsh
versions, install this repository and use `scripts/update-dsh.sh` instead of a
prebuilt release.

## Upstream sync

This repository does not fork `deepseek-ai/deepseek-harness`. It installs dsh from npm (`scripts/02-install-dsh.sh`), so each rebuild tracks the latest published version. The two patches are the only local delta, and they target compiled npm lib files rather than source.

## License

[MIT](LICENSE)