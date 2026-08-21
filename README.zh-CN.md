# dsh-termux

在 Termux(Android)上运行 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)(`dsh`),无需 root。

[English](README.md)

## 这个项目是什么

`dsh-termux` 是一套让 `dsh` 跑在 Termux 里的安装与维护脚本。装好之后,你可以像在电脑上一样在手机上使用 `dsh`:命令行对话、`dsh web` 网页界面、无头模式跑任务。

### 它和常见的 Termux 部署方案有什么不同

在 Termux 上部署 `dsh` 的主流思路,是直接在 Termux 自带的 Bionic libc 下跑 Node,并逐个解决原生模块的兼容问题。本项目的做法是换一条路:用 glibc 运行时跑官方 Node。

| | 常见的 Bionic 方案 | 本项目 |
|---|---|---|
| 运行时 | Termux 自带 Node(Bionic libc) | 官方 Node linux-arm64 + `grun`(glibc) |
| 原生模块 | 需要逐个处理,常见麻烦包括:koffi 的 `statx` 补丁、sharp / node-pty 缺 Android 二进制或需在 Bionic 下重新编译 | 全部直接命中 npm 上的 linux-arm64 预编译二进制,**无需编译** |
| 补丁数量 | 视版本变化,通常好几个、且随上游漂移 | 仅 2 个(见下),目标文件 byte 级锚定、CI 每轮校验 |
| 依赖 | 取决于是否引入 glibc 环境 | `glibc-repo` + `glibc` + `glibc-runner` |
| 与官方 dsh 的一致性 | 高 | 高(直接从 npm 安装,仅打补丁,不 fork 上游) |

glibc 环境下 `process.platform` 报告为 `linux`,npm 因此自动解析 linux-arm64 预编译原生模块(koffi、node-pty、sharp),省掉了最烦人的那部分。

本项目仍然需要 2 个小补丁,针对 Android 的文件系统限制:SELinux 禁止在应用私有存储里创建硬链接,而 dsh 的会话存储和 write 工具用 `link()` 发布文件,在 Android 上会报 `EACCES`。补丁在平台拒绝链接时回退到 `rename()`。细节见 [PATCHES.md](PATCHES.md)。

## ⚠ 测试状态与已知风险(请先读)

这个项目是一个**个人维护的小项目**,请带着合理预期使用:

- 主要由作者一人维护,目前**只在作者自己的一台设备上完整测试过**;
- 仓库里的 CI 只验证「补丁能干净应用到 npm 最新发布版 + 在标准 Linux 主机上能启动冒烟」,**并不覆盖真实的 Termux 安装流程**;
- 预构建 release、`install.sh`、多台设备/不同 Android 版本等场景**都还没有经过充分测试**;
- `dsh` 本身还在快速迭代,上游版本更新后可能出现补丁漂移、或尚未被本项目测试到的新问题。

也就是说:**可能存在隐藏的问题**。使用即代表你接受自行承担风险;如果有重要数据,请先备份。

同时也要说清楚目前已知可用的部分:安装、更新、2 个补丁、`dsh web` 启动在本项目维护的设备上都实测通过,CI 每次推送/PR 也会做一遍补丁校验 + 启动冒烟。

## 安装

> 目前仅支持 **arm64** 设备(绝大多数现代 Android 手机都是 arm64)。

### 1. 安装依赖

```sh
pkg install glibc-repo
pkg install glibc glibc-runner
```

### 2. 克隆并运行安装脚本

```sh
git clone https://github.com/ErEbusE/dsh-termux.git
cd dsh-termux
bash scripts/00-setup.sh
```

脚本会引导你完成:下载 Node linux-arm64 → 从 npm 安装 dsh → 应用补丁 → 启动 web。不想逐项确认可以加 `-y` 全自动:

```sh
bash scripts/00-setup.sh -y
```

> 注:安装过程不要求配置 API key 也能完成;使用 `dsh` 对话时按官方文档配置(配置文件在 `~/.dsh/`,可通过环境变量覆盖,详见官方 README)。

### 3. 验证

```sh
dsh --version    # 显示当前安装的版本(跟随 npm,版本号会变化)
dsh web --port 3080
```

`dsh web` 会打印 `http://127.0.0.1:3080`,手机浏览器打开即可使用网页界面。

### 安装改动了什么

| 内容 | 位置 |
|---|---|
| Node + dsh + 补丁后的依赖 | `$HOME/.local/opt/dsh-termux-runtime/` |
| `dsh` 命令(grun 转发包装脚本) | `$HOME/.local/opt/dsh-termux-runtime/work/dsh` |
| `dsh` 软链接 | `$HOME/.local/bin/dsh` |
| PATH 注入(带 `# dsh-termux` 标记) | `~/.bashrc` 末尾 |

## 使用

```sh
dsh --version                  # 查看版本
dsh web --port 3080            # 启动网页界面
dsh --profile headless "..."   # 无头模式跑一次任务
```

`dsh` 命令与官方 CLI 行为一致,参数说明以官方文档为准。

### 更新 dsh

dsh 更新很快。更新到 npm 的 `next` 标签并自动接受所有确认:

```sh
bash scripts/update-dsh.sh -t next -y
```

| 参数 | 作用 |
|---|---|
| `-t, --tag TAG` | 直接安装某个 npm dist-tag(如 `next`),不弹版本菜单 |
| `-v, --version VER` | 直接安装某个精确版本(如 `0.1.1-rc.1`),不弹版本菜单 |
| `-y, --yes` | 自动接受所有确认 |
| (不带 `-t`/`-v`) | 交互式版本菜单,回车默认 `latest` |

更新器会:安装所选版本 → 自动重打 2 个补丁并校验 → 更新 `dsh` 包装脚本。如果新版本改动了补丁目标文件导致无法打上,脚本会**明确报错并停止**(不会静默装一个坏掉的版本),这种情况说明需要重新生成补丁,见 [PATCHES.md](PATCHES.md)。

> 注意:更新**不会**自动重启正在运行的 `dsh web`。更新后手动 `dsh web --port 3080` 才会用上新版本。

## 常见问题

**更新时报"补丁不适用 / version drift"?**
说明 npm 上新发布的 dsh 改动了补丁目标文件。这是预期内的保护机制——此时 dsh 会保持已安装状态但未打补丁,Android 上会话保存/write 工具可能报 `EACCES`。请在 Issues 里提报或参考 PATCHES.md 重新生成补丁。

**数据存在哪里?**
dsh 自身数据在 `~/.dsh/`(官方路径);本项目的运行时在 `~/.local/opt/dsh-termux-runtime/`。

**怎么卸载?**
1. 编辑 `~/.bashrc`,删除带有 `# dsh-termux` 标记的那一行;
2. `rm ~/.local/bin/dsh`;
3. `rm -rf ~/.local/opt/dsh-termux-runtime`(如不需要再保留 dsh 数据,可同时删除 `~/.dsh`,请先确认里面没有你要保留的东西)。

## 工作原理(想了解细节再看)

1. **glibc 运行时**:通过 Termux 的 `glibc-runner`(`grun`)运行官方 Node.js linux-arm64 二进制。glibc 下 `process.platform === "linux"`,npm 直接命中 linux-arm64 预编译原生模块,**不需要源码编译**。
2. **仅剩 2 个补丁**:都针对同一个 Android 平台行为——SELinux 禁止在应用私有存储创建硬链接。dsh 的会话存储与 write 工具用 `link()` 发布文件,在 Android 上以 `EACCES` 失败;补丁让它们在被平台拒绝时回退到 `rename()`。补丁作用于 npm 包内编译后的 `lib/*.js`,每个补丁的目的、锚点与重新生成方法见 [PATCHES.md](PATCHES.md)。

## 仓库结构

```
dsh-termux/
├─ patches/                  Android 硬链接补丁(npm lib 文件)
│   ├─ npm-dsh-session-persistence-jsonl-link-rename.patch
│   └─ npm-dsh-fs-local-link-rename.patch
├─ scripts/                  Termux 设备上的安装/更新脚本
│   ├─ 00-setup.sh           入口:环境配置并依次驱动 01→04
│   ├─ 01-setup-glibc-node.sh
│   ├─ 02-install-dsh.sh
│   ├─ 03-apply-patches.sh
│   ├─ 04-run-web.sh         wrapper + PATH 配置 + 启动 web
│   ├─ update-dsh.sh         更新到所选版本并重新校验补丁
│   ├─ common.sh / patch-lib.sh   共享辅助函数(补丁逻辑同时被 CI 复用)
├─ build/                    CI / 离线构建(在 arm64 Linux 上运行)
│   ├─ build-runtime.sh      下载 node + 安装 dsh + 打补丁 + 校验
│   └─ install.sh            release 压缩包自带的自包含安装器
├─ .github/workflows/        CI:验证补丁(build.yml)+ 产出 release(release.yml)
├─ PATCHES.md                补丁用途、锚点、重新生成流程
└─ README.md / README.zh-CN.md
```

> 运行时产物(`node/`、`work/`、`downloads/`)生成在 `~/.local/opt/dsh-termux-runtime`,不属于本仓库,默认已被 `.gitignore` 忽略。

## 维护者文档(普通用户无需阅读)

- **CI**:每次 push/PR 验证两个补丁能干净应用到 npm 最新发布版,并在标准 Linux 主机上做「全新安装 + 打补丁 + `dsh --version` + `dsh web` 返回 HTTP 200」冒烟;`release.yml` 在 arm64 runner 上构建发布产物(手动触发或推送 `v*` tag)。
- **补丁维护**:补丁漂移时重新生成流程见 [PATCHES.md](PATCHES.md)。
- **与上游关系**:本项目不 fork `deepseek-ai/deepseek-harness`,而是从 npm 安装官方发布包;2 个补丁是唯一的本地增量。

## 遇到问题?

欢迎在 [Issues](https://github.com/ErEbusE/dsh-termux/issues) 提报。请附上:设备型号 / Android 版本、Termux 版本(`termux-info`)、出错命令的完整输出。

## 许可证

[MIT](LICENSE)
