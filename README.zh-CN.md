# dsh-termux

在 Termux(Android)上运行 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)(`dsh`)。

[English](README.md)

## 方案

本项目通过 Termux 的 [glibc-runner](https://github.com/termux-pacman/glibc-packages)(`grun`)运行官方 Node.js linux-arm64 二进制(glibc)。

glibc Node 下 `process.platform` 报告为 `linux`,npm 会自动解析 linux-arm64 预编译原生模块(koffi、node-pty、sharp),无需源码编译。

仍有两个补丁,针对 Android SELinux 策略的一项平台行为:它在应用私有存储中禁止创建硬链接。dsh 的会话存储和 write 工具使用 `link()` 发布文件;在 Android 上会失败并报 `EACCES`。两个补丁在平台拒绝链接时回退到 `rename()`。

## 环境要求

- Termux(arm64)
- glibc-repo、glibc、glibc-runner(`pkg install glibc-repo`,再 `pkg install glibc glibc-runner`)

## 快速开始(Termux)

```sh
git clone https://github.com/ErEbusE/dsh-termux.git
cd dsh-termux

bash scripts/00-setup.sh            # 默认值,每步询问
bash scripts/00-setup.sh -y         # 默认值,完全非交互
bash scripts/00-setup.sh --interaction   # 交互式配置环境 + 询问
```

`00-setup.sh` 驱动整个流程:

| 脚本 | 作用 |
|---|---|
| `00-setup.sh` | 入口;默认使用默认环境值(除非 `--interaction`);`-y` 自动接受所有询问 |
| `01-setup-glibc-node.sh` | 检测 Termux + glibc 组件(缺则询问安装),下载官方 Node linux-arm64 |
| `02-install-dsh.sh` | `npm install @deepseek-ai/dsh --ignore-scripts` |
| `03-apply-patches.sh` | 应用 Android 硬链接补丁 |
| `04-run-web.sh` | 生成 `dsh` 包装脚本、链接到 PATH、追加 `~/.bashrc` 标记、启动 web |

安装后,`dsh` 命令与官方 CLI 行为一致:

```sh
dsh --version                # 0.1.0-rc.7
dsh web --port 3080          # 启动浏览器 UI
dsh --profile headless "..." # 运行单次任务
```

包装脚本位于 `$HOME/.local/opt/dsh-termux-runtime/work/dsh`,是一个透明的 `grun` 转发器。`04-run-web.sh` 会把它软链接到 bin 目录(默认 `$HOME/.local/bin`)并在 `~/.bashrc` 中把该目录加入 PATH 最前(标记 `# dsh-termux`)。

### 参数与模式

```sh
bash scripts/00-setup.sh                  # 默认值,每步询问
bash scripts/00-setup.sh --interaction    # 交互式配置环境 + 询问
bash scripts/00-setup.sh -y               # 默认值,自动接受所有询问
bash scripts/00-setup.sh --interaction -y # 交互配置环境,自动接受安装
```

环境变量有输入校验:运行时目录必须是绝对路径且不含空格(grun 无法处理空格),Node 版本必须匹配 dsh 的 engines(`^22.19.0 || >=24.0.0`)。

### 更新 dsh

`update-dsh.sh` 从 npm 重装 dsh 到所选版本,并针对新安装的 lib 重新校验补丁:

```sh
bash scripts/update-dsh.sh                  # 交互式选择版本
bash scripts/update-dsh.sh -y               # 更新到 latest,自动接受
bash scripts/update-dsh.sh -v 0.1.0-rc.8    # 更新到指定版本
bash scripts/update-dsh.sh -t next          # 更新到某个 dist-tag(如 next)
```

| 参数 | 作用 |
|---|---|
| `-v, --version VER` | 安装精确版本(覆盖 tag 选择) |
| `-t, --tag TAG` | 安装某个 npm dist-tag(默认 `latest`) |
| `-y, --yes` | 自动接受所有询问 |

更新器会打印可用 dist-tags,以 `--ignore-scripts` 安装,然后先反向还原旧补丁再重新应用,以确保补丁与已安装版本匹配。若补丁不再匹配,会报告版本漂移(重新生成见 [PATCHES.md](PATCHES.md))。

更新器**不管理运行中的 web 实例**。更新后用 `dsh web --port 3080` 自行启动或重启 web,保持更新器无副作用。

## 补丁列表

| 补丁 | 解决的问题 |
|---|---|
| `npm-dsh-session-persistence-jsonl-link-rename.patch` | Android 上会话保存报 `EACCES`,因为会话存储用 `link()` 发布文件;平台拒绝链接时回退到 `rename()` |
| `npm-dsh-fs-local-link-rename.patch` | Android 上 write 工具报 `EACCES`,因为它在 `createIfAbsent` 模式下用 `link()` 发布;平台拒绝链接时回退到 `rename()` |

详见 [PATCHES.md](PATCHES.md)的用途、锚点与重新生成流程。

## 仓库结构

```
patches/         # Android 硬链接补丁(npm lib 文件)
  npm-dsh-session-persistence-jsonl-link-rename.patch
  npm-dsh-fs-local-link-rename.patch
PATCHES.md       # 每个补丁的用途、锚点、重新生成流程
scripts/         # 设备侧安装/更新脚本(在 Termux 上运行)
  common.sh                # 共享提示/校验辅助函数
  patch-lib.sh             # 共享的补丁应用/校验辅助函数(CI 也复用)
  00-setup.sh              # 入口:环境配置 + 驱动 01-04
  01-setup-glibc-node.sh
  02-install-dsh.sh
  03-apply-patches.sh
  04-run-web.sh            # 包装脚本 + PATH 配置 + 启动 web
  update-dsh.sh           # 重装到所选版本 + 重新校验补丁
build/           # CI/离线构建工具(在 arm64 Linux 上运行)
  build-runtime.sh        # 拉取 node + 安装 dsh + 打补丁 + 校验(无交互)
  install.sh              # 打进 release 压缩包的自包含安装脚本
.github/workflows/  # CI:验证补丁(build.yml)+ 产出 release(release.yml)
```

运行时产物(`node/`、`work/`、`downloads/`)生成于 `$DSH_RUNTIME_DIR`(默认 `$HOME/.local/opt/dsh-termux-runtime`),不属于本仓库。

## CI

- **`.github/workflows/build.yml`** 在每次 push/PR 时验证:补丁能干净应用到已发布的 npm 包,并在标准 Linux 主机上通过「全新 `npm install --ignore-scripts` + 打补丁 + 启动冒烟(`dsh --version`,以及 `dsh web` 能返回 HTTP 200)」。它通过 `scripts/patch-lib.sh` 应用补丁——与设备侧脚本走同一条代码路径。
- **`.github/workflows/release.yml`** 在原生 arm64 runner(`ubuntu-24.04-arm`)上产出可分发的运行时。它调用 `build/build-runtime.sh`:拉取 linux-arm64 Node 二进制、以 `--ignore-scripts` 安装 dsh、应用并校验补丁、然后做启动冒烟。触发方式:手动(`workflow_dispatch`,可指定 dsh npm spec 与 tag)或推送 `v*` tag。

## Release 产物

`release.yml` 会附带两个文件:

- `dsh-termux-runtime-<tag>.tar.gz` — `node/`(linux-arm64 Node)与 `work/`(已打补丁的 dsh + node_modules)的压缩包,在 arm64 Linux 主机上构建。
- `install.sh` — 自包含安装脚本,在目标 Termux 设备上运行。

在 Termux 上安装一个 release:

```sh
pkg install glibc-repo && pkg install glibc glibc-runner
bash install.sh -y              # 解压到 $HOME/.local/opt/dsh-termux-runtime,
                                # 生成 grun wrapper,软链 ~/.local/bin/dsh,
                                # 并向 ~/.bashrc 追加 PATH(标记 # dsh-termux)
```

### 兼容性说明

Release 产物是**构建时刻的快照**,仅针对其捆绑的 dsh 版本测试过。上游 dsh 持续演进,可能改动被补丁的文件;若补丁漂移,旧版本 release 可能失效。要跟进更新的 dsh 版本,请安装本仓库并用 `scripts/update-dsh.sh`,而非使用预构建 release。

## 上游同步

本仓库不 fork `deepseek-ai/deepseek-harness`,而是直接从 npm 安装 dsh(`scripts/02-install-dsh.sh`),每次重建都跟随最新发布版。两个补丁是唯一的本地增量,目标是编译后的 npm lib 文件而非源码。

## 许可证

[MIT](LICENSE)