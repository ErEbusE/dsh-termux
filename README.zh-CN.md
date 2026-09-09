# dsh-termux

在 Termux(Android)上运行 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)(`dsh`),无需 root。

[English](README.md) | [中文](README.zh-CN.md)

## 为什么这样做

在安卓上跑一个需要 glibc 的 Node 应用,一般方案是两条:要么把依赖全部对着 Termux 自带的(bionic)Node 重新编译,要么塞进 proot/glibc chroot。重新编译等于把 dsh 的整条原生依赖链 fork 成一份需要永久维护的第二构建;chroot 则多出一层转译,其文件语义与 activity 启动仍不符合安卓的规则。本项目走第三条路:在 Termux 自己的 glibc 运行时上安装**官方** Node.js linux-arm64 二进制——npm 预编译模块正是为这个构建编译的——上游 dsh 及其依赖原样运行,设备上从不编译任何东西。剩下的安卓特有问题(SELinux 链接策略、经 intent 的浏览器交接、Landlock 的 tmpdir 授权、跨站会话 cookie)只由一个小补丁集适配,随附的更新器每次运行都会重新校验它;完整清单见 [PATCHES.md](PATCHES.md)。

## 安装

> 仅支持 **arm64** 设备(几乎所有现代安卓手机都是 arm64)。

### 方案A:从 GitHub release 安装

```sh
pkg install glibc-repo
pkg install glibc glibc-runner
curl -fsSL https://github.com/ErEbusE/dsh-termux/releases/latest/download/install.sh | bash -s -- -y
```

安装器自动下载最新运行时 release、解包并配置好 `dsh` 命令。每个 release 内置的是发版时 dsh `latest` 的快照,具体版本号在 release tag 中。要固定某个 release,给命令加前缀 `DSH_RELEASE=<tag>`(tag 形如 `dsh-<内置 dsh 版本>-<项目版本>`,例如 `dsh-0.1.1-rc.2-1.0.1`)。

### 方案B:克隆项目本地安装

```sh
pkg install glibc-repo
pkg install glibc glibc-runner
git clone https://github.com/ErEbusE/dsh-termux.git
cd dsh-termux
bash scripts/00-setup.sh        # 加 -y 自动接受所有提示
```

区别:方案B 在安装时从 npm 解析 dsh(即当时发布的最新版),方案A 使用发版时的快照。两者最终布局相同,都带同一个内置更新器。

### 验证

```sh
dsh --version    # 打印已安装版本(跟随 npm,所以会变化)
dsh web --port 3080
```

`dsh web` 会打印 `http://127.0.0.1:3080` 并自动在手机浏览器中打开——启动时请让 Termux 保持**前台**(Android 10+ 会静默丢弃后台发起的 activity 启动);`dsh` 的行为与上游官方 CLI 完全一致,仅额外提供本项目添加的 `update` 命令(见[更新](#更新))。

## 更新

```sh
dsh update            # 交互式版本菜单(回车默认 latest)
dsh update -t next -y # 直接更新到 npm 的 next 标签,自动接受所有提示
dsh update --self     # 刷新补丁集并直接应用(不下载 npm 包)
```

`dsh update` 会更新 dsh 版本并重打安卓补丁(需要设备上装有 `git`:`pkg install git`)。
补丁集随本项目的 release 演进、不走 npm;每次更新发现更新 release 时会自动刷新。
`--self` 是「只打补丁」路径:从最新 release 刷新更新器 + 补丁集,并直接应用到已安装的
dsh,不下载新的 npm 包。

| 参数 | 作用 |
|---|---|
| `-t, --tag TAG` | 直接安装某个 dist-tag(如 `next`),不弹版本菜单 |
| `-v, --version VER` | 直接安装某个精确版本(如 `0.1.1-rc.2`),不弹版本菜单 |
| `-y, --yes` | 自动接受所有提示 |
| `--self` | 从最新 release 刷新更新器 + 补丁集并直接应用(不做 npm 更新;`-t`/`-v` 被忽略) |
| `--patch-set PATH` | 用本地补丁集(含 `scripts/` + `patches/` + `VERSION` 的目录或 `.tar.gz`)代替下载;隐含 `--self`,可离线 |
| `--force` | 与 `--self`/`--patch-set` 同用:机件未变化时也强制重打 |
| (不带 `-t`/`-v`) | 交互式版本菜单,回车默认 `latest` |

`dsh update` 不会重启正在运行的 `dsh web`,更新后请自己重新启动。

## 安装会在本地环境中做什么与卸载指导

安装只改动三处:把自含的运行时(Node + 打过补丁的 dsh + 更新器)解包到 `~/.local/opt/dsh-termux-runtime/`,在 `~/.local/bin/dsh` 放一个命令符号链接,并在 `~/.bashrc` 末尾追加一行带 `# dsh-termux` 标记的 PATH 配置。dsh 自己的数据(配置、会话)独立存放在 `~/.dsh/`。

卸载——删除文件:

```sh
rm ~/.local/bin/dsh
rm -rf ~/.local/opt/dsh-termux-runtime
rm -rf ~/.dsh    # dsh 的数据(配置/会话);确认不需要再删——删前仔细核对
```

另外,`~/.bashrc` 中带 `# dsh-termux` 标记的那一行需要手动删除。

## 常见问题

**`dsh web` 打不开浏览器?**
最常见原因:启动时 Termux 在后台——Android 10+ 会静默丢弃后台应用发起的 activity 启动。让 Termux 保持前台,或手动打开打印出的 URL。背景细节见[修复 3](PATCHES.md#fix-3-browser-handoff)。

**更新时报 "Patch does not apply / version drift"?**
说明 npm 上新发布的 dsh 改动了补丁目标文件。这是预期内的保护机制——此时 dsh 保持已安装但未打补丁,Android 上会话保存/write 工具可能报 `EACCES`。请到 [Issues](https://github.com/ErEbusE/dsh-termux/issues) 提报,或按 [PATCHES.md](PATCHES.md) 重新生成补丁。

**装了很久没更新,`dsh update` 不识别?**
1.1.0 之前的 runtime 没有包装脚本快捷方式:直接运行内置更新器——`bash ~/.local/opt/dsh-termux-runtime/scripts/update-dsh.sh -t next -y`。升到 1.1.0+ 后 `dsh update` 快捷方式会随每次更新自我保持;1.2.1 之前的 runtime 还没有补丁集自动刷新(更新会带着旧补丁集继续,并有提示),用方案A 重装一次即可全部补齐。

**我的数据在哪里?**
dsh 自身的数据在 `~/.dsh/`(上游默认);本项目的运行时在 `~/.local/opt/dsh-termux-runtime/`。

## 贡献者指南

欢迎提交 Issue 和 PR。贡献者工作流程——测试门槛(沙箱 + 真机实测)、CI、发布、更新机制内部细节——见 [CONTRIBUTING.md](CONTRIBUTING.md);每条安卓修复的原理与补丁漂移的再生流程见 [PATCHES.md](PATCHES.md)。如果用 AI 代理开发,[AGENTS.md](AGENTS.md) 是代理必须遵守的仓库协议。

## 项目结构

```
dsh-termux/
├─ patches/                  Android 补丁(作用于 dsh 的 npm 编译产物)
├─ scripts/                  安装/更新流水线(在 Termux 上运行)
│   ├─ 00-setup.sh           方案B 入口:环境配置,驱动 01→04
│   ├─ 01-setup-glibc-node.sh   下载 Node 并把 ELF interpreter 指向 glibc
│   ├─ 02-install-dsh.sh / 03-apply-patches.sh / 04-run-web.sh
│   ├─ update-dsh.sh         更新器:版本切换 + 重打补丁 + 重写包装脚本
│   └─ common.sh / patch-lib.sh  共享助手(包装脚本与 $BROWSER 打开器生成、
│                                补丁登记表;CI 复用)
├─ build/                    CI / 离线构建工具(arm64 Linux)
│   ├─ build-runtime.sh      构建 release tarball(node + dsh + 补丁 + 校验)
│   └─ install.sh            自包含安装器(release 产物,也在 tarball 内)
├─ .github/workflows/        CI:静态门槛(verify)+ npm 补丁哨兵(patch-check)
│                            + 稳定发布 + 源码构建 pre 发布
├─ .test-install/            沙箱测试体系:六条路线 + serve.sh 人类点检
├─ VERSION / NODE_VERSION    项目发布号(X.Y.Z;tag 为 dsh-<dsh 版本>-<VERSION>)/ 构建运行时使用的 Node 版本
├─ README.md / README.zh-CN.md   用户文档:安装 / 更新 / 卸载
├─ PATCHES.md                全部修复与适配的唯一索引 + 补丁机制
├─ CONTRIBUTING.md           贡献者工作流:测试门槛、CI、发布
└─ AGENTS.md                 AI 代理协议(测试真实性、沙箱边界)
```

> 运行时产物(`node/`、`work/`、`downloads/`)构建在仓库之外——`~/.local/opt/dsh-termux-runtime/` 下。

## 可用性声明

这是一个小型业余项目。作者每天在一台 arm64 手机上使用它,安装、更新、各补丁和 `dsh web` 都正常工作。CI 会把补丁集应用到最新 npm 版 dsh 并在 Linux 上对新安装做启动冒烟测试,但没有任何自动化步骤真正走一遍 Termux 实机安装,预编译产物也没在第二台设备上试过。上游 dsh 迭代很快:新版本可能改动补丁目标文件——此时更新器会报错停下而不是弄坏你的安装——在补丁路径之外,安卓仍可能出现本项目从未见过的问题。使用前请备份重要数据,放低预期,并[报告你遇到的问题](https://github.com/ErEbusE/dsh-termux/issues)。

## 许可证

[MIT](LICENSE)
