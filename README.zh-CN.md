# dsh-termux

在 Termux(Android)上运行 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)(`dsh`),无需 root。

[English](README.md) | 中文

## 这个项目是什么

`dsh-termux` 是一套让 `dsh` 跑在 Termux 里的安装与维护脚本。装好之后,你可以像在电脑上一样在手机上使用 `dsh`:命令行对话、`dsh web` 网页界面、无头模式跑任务。

Node 跑在 [glibc-runner](https://github.com/termux-pacman/glibc-packages) 提供的 glibc 运行时上,但启动器**直接 exec** Node 二进制,不走 `grun` 的 `ld.so <node>` 间接层 —— 那条路会让 `process.execPath` 变成动态链接器而不是 node,凡是 dsh 里自我 respawn 的功能都会坏(`dsh web` 的浏览器交接最明显),参数也会被词分割。详见[浏览器交接](#浏览器交接dsh-web)。

### 它和常见的 Termux 部署方案有什么不同

在 Termux 上部署 `dsh` 的主流思路,是直接在 Termux 自带的 Bionic libc 下跑 Node,并逐个解决原生模块的兼容问题。本项目的做法是换一条路:用 glibc 运行时跑官方 Node。

| 运行时 | Termux 自带 Node(Bionic libc) | 官方 Node linux-arm64 + Termux glibc 运行时,直接 exec(不经 `ld.so` 间接层) |
| 原生模块 | 需要逐个处理,常见麻烦包括:koffi 的 `statx` 补丁、sharp / node-pty 缺 Android 二进制或需在 Bionic 下重新编译 | 全部直接命中 npm 上的 linux-arm64 预编译二进制,**无需编译** |
| 补丁数量 | 视版本变化,通常好几个、且随上游漂移 | 仅 2 个(见下),目标文件 byte 级锚定、CI 每轮校验 |
| 依赖 | 取决于是否引入 glibc 环境 | `glibc-repo` + `glibc` + `glibc-runner` |
| 沙盒 | 官方 Landlock 沙盒后端跑不起来:要么不开沙盒、全程 full access;要么用 proot 在 Termux 上自建——但 proot 工作区之外一律不可读,与 `workspace-write`「工作区可写、其余全局可读」的语义相冲突,实际用起来很别扭 | 内核的 Landlock 原生可用,官方沙盒后端照常运行,`workspace-write` 语义完整 |

还有一处 Android 差异**不需要补丁**就已解决:`dsh web` 的浏览器交接 —— 见[浏览器交接](#浏览器交接dsh-web)。

glibc 环境下 `process.platform` 报告为 `linux`,npm 因此自动解析 linux-arm64 预编译原生模块(koffi、node-pty、sharp),省掉了最烦人的那部分。本项目从 npm 安装 dsh 官方发布包,不修改上游源码;仅剩的 2 个小补丁针对 Android 的文件系统限制——SELinux 禁止在应用私有存储里创建硬链接,而 dsh 的会话存储和 write 工具用 `link()` 发布文件,在 Android 上会报 `EACCES`。补丁让它们在平台拒绝链接时回退到 `rename()`,细节见 [PATCHES.md](PATCHES.md)。

## 现状与限制

先说清楚:这个项目目前只有作者一个人在维护和使用,所有测试也都只在作者自己的设备上做过。

**测试到哪一步**:作者在自己的一台 arm64 手机上日常使用,安装、更新、两个补丁和 `dsh web` 都在这台设备上跑通过。仓库的 CI 会在每次推送时把补丁应用到 npm 最新发布版,并在 Linux 上做一次全新安装的启动冒烟——但没有任何自动化环节真正走过 Termux 安装流程;预构建 release 和 `install.sh` 也还没在第二台设备上试过。

**已知短板**:上游 dsh 迭代很快,新版本可能改动补丁目标文件导致补丁失效(这种情况更新脚本会直接报错停下,不会装出一个坏掉的环境);除了补丁覆盖的两处代码路径,dsh 在 Android 上仍可能遇到这个项目没碰到过的问题。

所以用之前请备份重要数据,遇到问题欢迎发到 [Issues](https://github.com/ErEbusE/dsh-termux/issues)。

## 安装

> 目前仅支持 **arm64** 设备(绝大多数现代 Android 手机都是 arm64)。

### 方式 A:一键脚本(安装最新预构建 release)

```sh
pkg install glibc-repo
pkg install glibc glibc-runner
curl -fsSL https://github.com/ErEbusE/dsh-termux/releases/latest/download/install.sh | bash -s -- -y
```

安装器会自动下载最新的 runtime release 并完成解包和 `dsh` 命令配置。想固定某个版本(tag 名为 `dsh-<捆绑的dsh版本>-<项目VERSION>`,例如 `dsh-0.1.1-rc.1-1.0.0`):

```sh
DSH_RELEASE=dsh-0.1.1-rc.1-1.0.0 curl -fsSL https://github.com/ErEbusE/dsh-termux/releases/latest/download/install.sh | bash -s -- -y
```

release 是打包时刻的快照;装完可用自带的更新器跟进上游(见下文「更新 dsh」)。

### 方式 B:clone 本仓库现场安装

```sh
pkg install glibc-repo
pkg install glibc glibc-runner
git clone https://github.com/ErEbusE/dsh-termux.git
cd dsh-termux
bash scripts/00-setup.sh            # 加 -y 可全自动
```

区别在于:方式 B 在安装时从 npm 解析**当时最新**的 dsh 版本,方式 A 用的是 release 打包时的快照。两者最终目录布局完全一致,都自带更新器。

### 验证

```sh
dsh --version    # 显示当前安装的版本(跟随 npm,版本号会变化)
dsh web --port 3080
```

`dsh web` 会打印 `http://127.0.0.1:3080`,手机浏览器打开即可使用网页界面。

> 注:安装过程不要求配置 API key 也能完成;使用 `dsh` 对话时按官方文档配置(配置文件在 `~/.dsh/`,可通过环境变量覆盖,详见官方 README)。

### 安装改动了什么

| 内容 | 位置 |
|---|---|
| Node + dsh + 补丁后的依赖 | `$HOME/.local/opt/dsh-termux-runtime/` |
| `dsh` 包装脚本(直接 exec Node) | `$HOME/.local/opt/dsh-termux-runtime/work/dsh` |
| `$BROWSER` 打开器(Android intent) | `$HOME/.local/opt/dsh-termux-runtime/work/dsh-termux-open` |
| `dsh` 软链接 | `$HOME/.local/bin/dsh` |
| PATH 注入(带 `# dsh-termux` 标记) | `~/.bashrc` 末尾 |
| Node ELF interpreter | 指向 Termux 的 glibc loader,让内核能直接 exec node |

## 使用

```sh
dsh --version                  # 查看版本
dsh web --port 3080            # 启动网页界面
dsh --profile headless "..."   # 无头模式跑一次任务
```

`dsh` 命令与官方 CLI 行为一致,参数说明以官方文档为准。

### 浏览器交接(`dsh web`)

`dsh web` 会自动打开手机默认浏览器。这件事以前被**两个互相独立**的 Termux 问题挡住,都已在不给 dsh 打补丁的前提下修好。

**1. `process.execPath` 不是 node,而是 glibc 的动态链接器。** dsh 通过重新 spawn 自己(`spawn(process.execPath, …)`)来跑打开器。`grun` 启动 glibc 程序的方式是 `ld.so <binary>`,所以内核实际执行的程序 —— 也就是 `/proc/self/exe` 和 `process.execPath` —— 是 `ld-linux-aarch64.so.1`。于是那次 spawn 把 Node 的参数喂给了链接器:

```
web-app: could not open the default browser because
/data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1: unrecognized option '--input-type=module'
```

打开器子进程在 `import('open')` 之前就死了。修法:安装时把 Node 的 ELF interpreter 指向 Termux 的 glibc loader(安全地做 —— 复制、打补丁、验证、原子替换;两个陷阱见 [PATCHES.md](PATCHES.md)),wrapper 直接 exec Node。这同时修掉了参数词分割 —— `grun` 有两处 `$@` 没加引号,`dsh "两个 词"` 以前会变成两个 argv。

**2. `open` 包在 Android 上找不到浏览器。** glibc Node 下 `process.platform` 是 `linux`,于是 `open` 优先使用它自带的 freedesktop `xdg-open` 脚本。Android 没有 freedesktop 桌面环境,该脚本会依次尝试 `x-www-browser`/`firefox`/`lynx`/`w3m`… 全部找不到,最后以 exit 3 报 `no method available`;而 dsh 只等待 spawn 成功,所以它不报错,浏览器也永远不会弹出。

包装脚本把 `$BROWSER` 指向同目录的 `work/dsh-termux-open` —— 一个很小的 Android intent 打开器。它按参数分发,因为 dsh 的两个调用点交给 `$BROWSER` 的东西不同:

| dsh 传入 | 打开器调用 | 原因 |
|---|---|---|
| `http(s)://…` —— 即 `dsh web` 的 URL | `termux-open-url` | `am start -a android.intent.action.VIEW -d <url>` |
| `.html`/`.htm`/`.xhtml`/`.svg` 的**文件路径** | `termux-open` | `am start -d <裸路径>` 没有 scheme,无法解析 Intent(exit 1);只有 `TermuxOpenReceiver` 会为本地文件构造 `content://` URI |

- 无需额外安装:两个打开器都来自 `termux-tools`(Termux 的 Essential 包)。**不需要** Termux:API。
- **启动 `dsh web` 时请让 Termux 处于前台。** Android 10+ 禁止后台应用启动 Activity,若先切走,intent 会被静默丢弃,而 `am` 仍然返回 0。
- 想换浏览器就自己 export `BROWSER`;想完全跳过交接、只用打印出的 URL,就用 `dsh web --no-open`。

### 更新 dsh

dsh 更新很快。更新到 npm 的 `next` 标签并自动接受所有确认:

```sh
bash scripts/update-dsh.sh -t next -y
```

用方式 A(release)安装的用户没有本仓库的 checkout,直接用安装时自带的更新器:

```sh
bash ~/.local/opt/dsh-termux-runtime/scripts/update-dsh.sh -t next -y
```

| 参数 | 作用 |
|---|---|
| `-t, --tag TAG` | 直接安装某个 npm dist-tag(如 `next`),不弹版本菜单 |
| `-v, --version VER` | 直接安装某个精确版本(如 `0.1.1-rc.2`),不弹版本菜单 |
| `-y, --yes` | 自动接受所有确认 |
| (不带 `-t`/`-v`) | 交互式版本菜单,回车默认 `latest` |

更新器会:安装所选版本 → 自动重打 2 个补丁并校验 → 更新 `dsh` 包装脚本。如果新版本改动了补丁目标文件导致无法打上,脚本会**明确报错并停止**(不会静默装一个坏掉的版本),这种情况说明需要重新生成补丁,见 [PATCHES.md](PATCHES.md)。

> 注意:更新**不会**自动重启正在运行的 `dsh web`。更新后手动 `dsh web --port 3080` 才会用上新版本。

## 常见问题

**`dsh web` 不打开浏览器?**
见[浏览器交接](#浏览器交接dsh-web)。最常见的原因:启动 `dsh web` 时 Termux 在后台 —— Android 10+ 会静默丢弃后台应用的 Activity 启动。让 Termux 保持前台,或手动打开打印出的 URL。

**更新时报"补丁不适用 / version drift"?**
说明 npm 上新发布的 dsh 改动了补丁目标文件。这是预期内的保护机制——此时 dsh 会保持已安装状态但未打补丁,Android 上会话保存/write 工具可能报 `EACCES`。请在 Issues 里提报或参考 PATCHES.md 重新生成补丁。

**数据存在哪里?**
dsh 自身数据在 `~/.dsh/`(官方路径);本项目的运行时在 `~/.local/opt/dsh-termux-runtime/`。

**怎么卸载?**
1. 编辑 `~/.bashrc`,删除带有 `# dsh-termux` 标记的那一行;
2. `rm ~/.local/bin/dsh`;
3. `rm -rf ~/.local/opt/dsh-termux-runtime`(如不需要再保留 dsh 数据,可同时删除 `~/.dsh`,请先确认里面没有你要保留的东西)。

## 跟随上游更新

本项目不从源码构建 dsh:每次运行安装或更新脚本,都会从 npm 拉取 `@deepseek-ai/dsh` 的指定版本(`latest` 或 `next` 等标签),因此始终能直接用上官方发布的新版本。本地增量只有 2 个补丁文件,它们作用于 npm 包内编译后的 `lib/*.js`;每次安装/更新结束时,脚本会把补丁应用到刚装好的文件上并校验结果。若某次上游更新改动了这些文件导致补丁无法应用,更新会明确报错停下——此时按 [PATCHES.md](PATCHES.md) 重新生成补丁即可继续跟进上游。

## 仓库结构

```
dsh-termux/
├─ patches/                  Android 硬链接补丁(npm lib 文件)
│   ├─ npm-dsh-session-persistence-jsonl-link-rename.patch
│   └─ npm-dsh-fs-local-link-rename.patch
├─ scripts/                  Termux 设备上的安装/更新脚本
│   ├─ 00-setup.sh           入口:环境配置并依次驱动 01→04
│   ├─ 01-setup-glibc-node.sh   下载 Node,并把其 ELF interpreter 指向 glibc loader
│   ├─ 02-install-dsh.sh
│   ├─ 03-apply-patches.sh
│   ├─ 04-run-web.sh         wrapper + PATH 配置 + 启动 web
│   ├─ update-dsh.sh         更新到所选版本并重新校验补丁
│   ├─ common.sh / patch-lib.sh   共享辅助函数(wrapper 生成器;补丁逻辑同时被 CI 复用)
├─ build/                    CI / 离线构建(在 arm64 Linux 上运行)
│   ├─ build-runtime.sh      下载 node + 安装 dsh + 打补丁 + 校验
│   └─ install.sh            自包含安装器(release 附带,也打进压缩包内)
├─ .github/workflows/        CI:验证补丁 + wrapper(build.yml)+ 产出 release(release.yml)
├─ VERSION                   项目发布号(X.Y.Z);tag 名为 dsh-<dsh版本>-<VERSION>
├─ PATCHES.md                补丁用途、锚点、重新生成流程
└─ README.md / README.zh-CN.md
```

> 运行时产物(`node/`、`work/`、`downloads/`)生成在 `~/.local/opt/dsh-termux-runtime`,不属于本仓库,默认已被 `.gitignore` 忽略。

## 参与贡献

欢迎 Issue 和 PR。

- **反馈问题**:请附上设备型号 / Android 版本、Termux 版本(`termux-info`)、出错命令的完整输出;
- **修复补丁漂移**:当上游更新使补丁失效时,按 [PATCHES.md](PATCHES.md) 的流程对新的 `lib/*.js` 重新生成两个 `.patch` 文件,并在 PR 里注明对应的 dsh 版本号;
- **改代码**:脚本改动请保持 `bash -n` 通过,并尽量在真实 Termux 上验证一遍再提交;涉及补丁应用逻辑(`scripts/patch-lib.sh`)的改动会被 CI 的补丁校验覆盖;`dsh` wrapper / `$BROWSER` 打开器的文本在 `scripts/common.sh` 与 `build/install.sh` 各有一份镜像,同样有 CI 守卫;
- **CI**:每次 push / PR 自动验证补丁能否干净应用到 npm 最新发布版,并做全新安装 + 启动冒烟;
- **发布**:项目版本号存于 `VERSION`(X.Y.Z),release 的 tag 名为 `dsh-<捆绑的dsh版本>-<VERSION>`。推送 `main` 或手动运行 release 工作流会触发发版,但前置有一个秒级闸门:与上次发布相比 `VERSION` 和可解析的 dsh 版本都没变时,直接跳过不发布。生成的 tag 已存在时工作流以硬错误退出(大概率是忘了 bump `VERSION`);`VERSION` 不比上次新则只是警告——上游 dsh 版本前进而 `VERSION` 保持不变是预期场景。手动运行同样遵循闸门。

## 许可证

[MIT](LICENSE)
