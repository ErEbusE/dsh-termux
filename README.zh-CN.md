# dsh-termux

在 Termux(Android)上运行 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)(`dsh`),无需 root。

[English](README.md) | [中文](README.zh-CN.md)

## 这个项目是什么

`dsh-termux` 是一套让 `dsh` 在 Termux 里跑起来的安装与维护脚本。它在 Termux 的 glibc 运行时上安装官方 Node.js **linux-arm64** 二进制,因此 dsh 本身永远不需要重新编译:npm 会直接解析 linux-arm64 预编译原生模块。为了让 dsh 适配 Android,项目做了一小批修复——完整清单见下表,细节都在 [PATCHES.md](PATCHES.md)。

## 针对 Termux 的修复与适配

本项目为了让 dsh 适配 Termux 环境所做的修复与适配,每行一条。细节见 [PATCHES.md](PATCHES.md)。

| 修复/适配 | 一句话简介 | 详情 |
|---|---|---|
| 会话保存与 write 工具报 `EACCES: link` | SELinux 禁止在应用私有存储中创建硬链接;补丁改为回退到 `rename()` | [补丁 1](PATCHES.md#patch-1-hard-link-eacces) |
| `dsh web` 交接子进程死掉;参数被拆词 | `process.execPath` 曾指向 glibc loader;启动器现在直接 exec node | [修复 2](PATCHES.md#fix-2-direct-exec) |
| `dsh web` 在 Android 上找不到浏览器 | `$BROWSER` 指向一个 Android intent 打开器 | [修复 3](PATCHES.md#fix-3-browser-handoff) |
| dsh 更新体验优化 | 包装脚本认识 `dsh update`,原样转交内置更新器 | [适配 4](PATCHES.md#fix-4-update-shortcut) |
| workspace-write 下沙箱内 bash 写不了 `$TMPDIR` | Landlock 沙箱方言的授权清单漏了 `os.tmpdir()`;补丁补上 | [补丁 5](PATCHES.md#patch-5-landlock-tmpdir) |

## 状态与限制

这是一个小型的业余项目:

**测试做到什么程度**:作者每天在一台 arm64 手机上使用 dsh-termux,安装、更新、各补丁和 `dsh web` 都正常工作。CI 在每次推送时都会把补丁应用到最新 npm 发布版,并在 Linux 上对新安装做启动冒烟测试——但没有任何自动化步骤真正走一遍 Termux 实机安装,预编译产物和 `install.sh` 也还没在第二台设备上试过。

**已知薄弱点**:上游 dsh 迭代很快,新版本可能改动补丁目标文件导致补丁失效(此时更新脚本会报错停下,而不是留给你一个坏掉的安装)。在各条补丁路径之外,Android 仍可能出现本项目从未见过的问题。

所以请放低预期:使用前备份重要数据,遇到问题请在 [Issues](https://github.com/ErEbusE/dsh-termux/issues) 里报告。

## 安装

> 仅支持 **arm64** 设备(几乎所有现代安卓手机都是 arm64)。

### 方式 A:一键安装(安装最新预编译 release)

```sh
pkg install glibc-repo
pkg install glibc glibc-runner
curl -fsSL https://github.com/ErEbusE/dsh-termux/releases/latest/download/install.sh | bash -s -- -y
```

安装器会自动下载最新运行时 release、解包并配置好 `dsh` 命令。要固定到某个特定 release(标签格式为 `dsh-<内置 dsh 版本>-<项目 VERSION>`,例如 `dsh-0.1.1-rc.2-1.0.1`):

```sh
DSH_RELEASE=dsh-0.1.1-rc.2-1.0.1 curl -fsSL https://github.com/ErEbusE/dsh-termux/releases/latest/download/install.sh | bash -s -- -y
```

每个 release 内置的是发版时 dsh 的 latest 版本快照,具体版本号显示在 release tag 中;以后可以用随附的更新器保持最新(见 [更新 dsh](#更新-dsh))。

### 方式 B:克隆本仓库并全新安装

```sh
pkg install glibc-repo
pkg install glibc glibc-runner
git clone https://github.com/ErEbusE/dsh-termux.git
cd dsh-termux
bash scripts/00-setup.sh        # 加 -y 自动接受所有提示
```

区别在于:方式 B 在安装时从 npm 解析 dsh(即当时发布的最新版),方式 A 则使用 release 时的快照。两者最终布局相同,都带同一个内置更新器。

### 验证

```sh
dsh --version    # 打印已安装版本(跟随 npm,所以会变化)
dsh web --port 3080
```

`dsh web` 会打印 `http://127.0.0.1:3080` 并在手机浏览器中打开它(见 PATCHES.md 的[修复 3](PATCHES.md#fix-3-browser-handoff))。

> 安装完成时不需要 API key;等你真正使用 `dsh` 时再按官方文档配置(配置在 `~/.dsh/`,可用环境变量覆盖)。

### 安装器会改动什么

对**用户环境**的更改只有这些:

| 项目 | 位置 |
|---|---|
| Node + dsh + 打补丁的依赖 | `$HOME/.local/opt/dsh-termux-runtime/` |
| `dsh` 符号链接 | `$HOME/.local/bin/dsh` |
| PATH 注入(带 `# dsh-termux` 标记) | `~/.bashrc` 末尾 |

## 用法

```sh
dsh --version                  # 显示版本
dsh web --port 3080            # 启动 Web UI
dsh update -t next -y          # 更新 dsh —— 见下方「更新 dsh」
```

`dsh` 命令与官方 CLI 行为一致,完整用法见上游文档。启动 `dsh web` 时请让 Termux 保持在前台——Android 10+ 会静默丢弃后台应用发起的 activity 启动。

## 更新 dsh

dsh 迭代很快。更新到 npm 的 `next` 标签:

```sh
dsh update -t next -y
```

这**不是上游 dsh 的功能**:上游顶层的子命令只有 `web` 和 `plugin`,所以本项目生成的 Termux 包装脚本可以安全地把首参数为 `update` 的调用接管下来——把其余参数原样交给下面的内置更新器(更新器缺失时会明确报错)。其余任何调用都原样直达 dsh 本体。

实际机制是运行 `update-dsh.sh`。例如等同于方式 B(克隆安装)下:

```sh
bash scripts/update-dsh.sh -t next -y
```

方式 A(release)的用户没有更新到 1.1.0 以上时——使用安装时内置的更新器:

```sh
bash ~/.local/opt/dsh-termux-runtime/scripts/update-dsh.sh -t next -y
```

升级到 1.1.0 之后,这条命令同样可以换成上面的 `dsh update`;此后该快捷方式随每次更新自动保持。

| 参数 | 作用 |
|---|---|
| `-t, --tag TAG` | 直接安装某个 dist-tag(如 `next`),不弹版本菜单 |
| `-v, --version VER` | 直接安装某个精确版本(如 `0.1.1-rc.2`),不弹版本菜单 |
| `-y, --yes` | 自动接受所有提示 |
| `--self` | 强制先从最新项目 release 刷新更新器+补丁集(落后时本来就会自动发生) |
| (不带 `-t`/`-v`) | 交互式版本菜单,回车默认 `latest` |

更新器会:安装所选版本 → 重新打补丁并校验 → 重写 `dsh` 包装脚本。如果新版本改动了补丁目标文件导致无法打上,脚本会**明确报错并停止**(不会静默装一个坏掉的版本)。这种情况说明需要重新生成补丁,见 [PATCHES.md](PATCHES.md)。

### 补丁集更新 vs npm 更新

`dsh update` 更新的是 **dsh 的 npm 版本**;**补丁集**(以及更新器本身)随项目 release 演进——新增或修改过的补丁装在本项目的新 release 里,不随 npm 分发。因此每次更新在动 npm 之前,都会先比对你 runtime 的 release 身份与 GitHub 最新 release,落后时**自动刷新补丁集**:下载轻量补丁包资产(~40KB:更新器自身三脚本 + 补丁 + `VERSION`),替换 runtime 内对应内容,再用新补丁集重跑更新。`dsh update --self -y` 则是显式强制执行同样的刷新。

1.2.1 之前的 runtime 没有 `VERSION` 可比对、也没有补丁包资产可取:更新会带着旧补丁集继续(带提示);要获得自更新机制,请用[一键安装](#方式-a一键安装安装最新预编译-release)覆盖安装。

两种安装方式的 runtime 都是自含的:更新器与补丁集随 runtime 一起安装,即使日后删除或移动了仓库克隆(方式 B),`dsh update` 依然可用。

> 更新器**不会**重启正在运行的 `dsh web`。更新后请自己运行 `dsh web --port 3080` 以加载新版本。

## FAQ

**`dsh web` 打不开浏览器?**
最常见原因:启动 `dsh web` 时 Termux 在后台——Android 10+ 会静默丢弃后台应用发起的 activity 启动。让 Termux 保持前台,或手动打开打印出的 URL。背景细节见[修复 3](PATCHES.md#fix-3-browser-handoff)。

**更新时提示 "Patch does not apply / version drift"?**
说明 npm 上新发布的 dsh 改动了补丁目标文件。这是预期内的保护机制——此时 dsh 保持已安装但未打补丁,Android 上会话保存/write 工具可能报 `EACCES`。请在 Issues 里提报,或按 [PATCHES.md](PATCHES.md) 重新生成补丁。

**我的数据在哪里?**
dsh 自身的数据在 `~/.dsh/`(上游默认);本项目的运行时在 `~/.local/opt/dsh-termux-runtime/`。

**如何卸载?**
1. 编辑 `~/.bashrc`,删掉带 `# dsh-termux` 标记的那行;
2. `rm ~/.local/bin/dsh`;
3. `rm -rf ~/.local/opt/dsh-termux-runtime`(如果不需要 dsh 的数据再删 `~/.dsh`——删之前请仔细确认)。

## 仓库布局

```
dsh-termux/
├─ patches/                  Android 补丁(npm lib 文件)
│   ├─ npm-dsh-session-persistence-jsonl-link-rename.patch
│   ├─ npm-dsh-fs-local-link-rename.patch
│   └─ npm-dsh-sandbox-local-landlock-tmpdir.patch
├─ scripts/                  安装/更新流水线(在 Termux 上运行)
│   ├─ 00-setup.sh           入口:环境配置,驱动 01→04
│   ├─ 01-setup-glibc-node.sh   下载 Node 并把 ELF interpreter 指向 glibc
│   ├─ 02-install-dsh.sh
│   ├─ 03-apply-patches.sh
│   ├─ 04-run-web.sh         包装脚本 + PATH 配置 + web 启动
│   ├─ update-dsh.sh         更新到指定版本 + 重新校验补丁
│   ├─ common.sh / patch-lib.sh   共享助手(包装脚本生成器 + 补丁逻辑,CI 复用)
├─ build/                    CI / 离线构建工具(arm64 Linux)
│   ├─ build-runtime.sh      下载 node + 安装 dsh + 打补丁 + 校验
│   └─ install.sh            自包含安装器(release 产物,也在 tarball 内)
├─ .github/workflows/        CI:校验补丁 + 包装脚本(build.yml)+ release(release.yml)
├─ VERSION                   项目发布号(X.Y.Z);tag 为 dsh-<dsh 版本>-<VERSION>
├─ PATCHES.md                修复与适配细节(补丁 + 环境修复)
└─ README.md / README.zh-CN.md
```

> 运行时产物(`node/`、`work/`、`downloads/`)创建在 `~/.local/opt/dsh-termux-runtime`,在本仓库之外(已被 `.gitignore` 忽略)。

## 贡献

欢迎提交 Issue 和 PR。

- **报告问题**:请附上设备型号 / Android 版本、Termux 版本(`termux-info`),以及失败命令的完整输出;
- **修复补丁漂移**:当上游更新使补丁失效时,按 [PATCHES.md](PATCHES.md) 的流程对新的 `lib/*.js` 重新生成受影响的 `.patch` 文件,并在 PR 里注明对应的 dsh 版本号;
- **新增 Termux 适配**:在 [PATCHES.md](PATCHES.md) 里加一节,并在本 README 顶部的修复表格里加一行;
- **代码修改**:脚本改动保持 `bash -n` 干净,并尽量在真实 Termux 设备上测试;补丁逻辑(`scripts/patch-lib.sh`)的改动有 CI 补丁检查覆盖;`dsh` 包装脚本与 `$BROWSER` 打开器的生成逻辑只在 `scripts/common.sh` 一处维护,`build/install.sh` 从 release 包内 source 同一份 `common.sh`,不再各自复制,CI 会校验 install.sh 没有内嵌副本;
- **CI**:每次 push / PR 都会校验补丁能干净地应用到 npm 最新版,外加一次全新安装的启动冒烟测试;
- **发布**:项目版本号在 `VERSION`(X.Y.Z),release tag 为 `dsh-<内置 dsh 版本>-<VERSION>`。版本发生变化并推送 `main` 时会自动发布;另外,当只有 dsh 上游出了新版、项目本身没有变化(自然也没有推送)时,作者会手动触发一次发版——这样方式 A 的新装用户可以直接从 release 拿到最新 dsh,而不用下载后再更新。若 `VERSION` 与内置 dsh 版本相对上一次发布均无变化,流程提前退出、不发布;已存在的 tag 会报错停止。

## 许可证

[MIT](LICENSE)