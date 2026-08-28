# AGENTS.md — dsh-termux 开发测试协议

本文件是**本地**代理指令文档：指导在本仓库工作的 AI 代理如何测试改动。
已加入 `.gitignore`，**不进入提交**。改动仓库代码前先阅读本文件。

## 0. 铁律：agent 的测试 ≠ 通过测试

> 禁止默认「agent 跑一下无头/冒烟测试（语法检查、沙箱安装、CI 绿）
> 就算通过测试」。

- agent 侧的任何测试（`bash -n`、CI、§1 沙箱安装）只是**必要不充分**的
  一层自动防护；
- 涉及安装、更新、补丁、浏览器交接等任何**会落到真机行为**的改动，最终
  都必须由**人类在真实 Termux 设备上实际使用和测试**，agent 不得代替判定;
- 每次把改动交付人类审阅时，必须附**最小、可照抄的手动实测步骤**
  （命令、预期结果、逐步检查点）；在人类明确回复「通过/已验证」之前，
  状态一律是**「待人类实测」**——不得宣称测试通过、不得合并、不得发布 release；
- 若改动确实无法真机验证（如无设备），必须如实标注「未实测」，
  绝不能假装通过，也不能把 agent 跑过的自动测试冒充为人类实测结果。

## 1. 沙箱测试方案（.test-install/）

`.test-install/` 是本地测试沙箱（已在 .gitignore 中，不会提交）：

```
.test-install/
├── run.sh                 # 唯一入口: r1|r2|r3|r4|r5|all|serve|baseline|clean
├── baseline.env           # 基线事实源（唯一数据处; 由 run.sh baseline set 写出）
├── sandbox-lib.sh         # 公共核心: 隔离导出/唯一 unset 清单/grun stub/断言计数/线上哨兵
├── routes/                # 五条路线的驱动+专属断言（共性全在 sandbox-lib.sh）
│   ├── r1-install.sh      # R1 工作区 install.sh × 基线 tarball（每次迭代必跑）
│   ├── r2-release.sh      # R2 下载 latest release 认证（--pinned 离线测 pin 资产）
│   ├── r3-setup.sh        # R3 工作区 00-setup 流水线（npm 源; 冷装 20min+）
│   ├── r4-update-ws.sh    # R4 更新链路(工作区更新器 × 种子沙箱)
│   └── r5-update-shipped.sh # R5 更新链路(tarball 内置更新器 = Option A 用户真实路径)
├── serve.sh               # 人类实测入口：沙箱内起 dsh web 供浏览器点检（§1.3）
├── release-test/          # 基线发布物本体（可从 GitHub 下载后长期复用）
│   ├── dsh-termux-runtime.tar.gz   # ~100MB
│   └── install.sh
└── sandbox-run/           # R1 隔离根：home/ tmp/ bin/ prefix/ + install.log
    # R2/R3/R4/R5 另有 sandbox-release/ sandbox-setup/ sandbox-update/（各自重跑自动重建; r4/r5 共用 sandbox-update 且不可并行）
```

### 1.1 基线发布物：唯一事实源是 baseline.env（一次 pin，命令化更新）

基线的 tag / sha256 / 内置 dsh 版本**只存在于一处**——`.test-install/baseline.env`。
所有路线的期望值都由它派生（没有任何脚本硬编码版本号）。管理命令：

```sh
bash .test-install/run.sh baseline check        # 随时查看: pin 内容/资产哈希/与 VERSION 是否漂移
bash .test-install/run.sh baseline set latest   # 发新版本后: latest 自动解析为实际 tag, 下载两资产->现算 sha256->原子写入
bash .test-install/run.sh baseline set <tag>    # 同上, 但钉住指定 tag (不随 latest 变)
```

> `set` 落盘的**永远是解析后的具体 tag**——`latest` 只作为输入别名存在：
> 基线必须可复现、可审计, 事实源里不存「随时会漂移」的值。解析走 GitHub 的
> releases/latest 重定向, 无需 token、不占 API 配额。嫌长可以加 alias:
> `alias dsh-baseline='bash .test-install/run.sh baseline'` → `dsh-baseline set latest`。

- 哈希一律**现算**，绝不手抄——不存在「抄错一位」这类事故面；
- `set` 用 wget 直连 GitHub（网络受限先 export https_proxy/http_proxy）；不需要 token；
- **基线一致性检查**：**消费基线的路线**（r1、r2 --pinned、r3、r4）启动时比对该 pin 与仓库 `VERSION`（r2 浮动/r5 不消费基线，不做此检查）。一致打印 ok；
  不一致只 **WARN 不阻塞**（gate 的结论只对「当前 VERSION 的安装脚本」有效），
  但 WARN 会集中出现在末尾 summary 里无法无视。发版后**必须**回来
  `baseline set <新tag>`——旧的手工三处同步义务（wget tag/sha256 打印值/文档哈希）已废除。

### 1.2 跑沙箱自动层（唯一入口 run.sh）

> 忘了命令就敲 `bash .test-install/run.sh help`——全部命令、开关与注意事项一屏带注释。

交付门槛就是一个命令：

```sh
bash .test-install/run.sh all              # = r1+r2+r4+r5 (--with-r3 再追加 r3)
bash .test-install/run.sh r1               # 单跑一条 (日常迭代只需这条)
```

五条路线共用公共核心（`sandbox-lib.sh`：隔离导出/唯一 unset 清单/grun stub/
ok-fail 计数/线上哨兵/基线加载），差异只剩各自的驱动与专属断言。判定标准统一：
**任何断言失败即 FAIL，禁止跳过或「只跑个大概」**；每条路线结束打印
`== [rN] done: N ok ==` 与集中 WARN。r4 与 r5 共用 `sandbox-update/` 目录，**不可并行**。

| 路线 | 命令 | 测什么 | 网络 | 备注 |
|---|---|---|---|---|
| R1 | `run.sh r1` | 工作区 `build/install.sh` × 基线 tarball 全安装接线（每次迭代必跑） | 无 | ~12s；期望版本取自 baseline.env |
| R2 | `run.sh r2`（`--pinned` 离线测 pin 资产） | **下载当前 latest release** 认证：shipped install.sh + tarball 完好（打包回归；发版产物未经真机检验，这条就是补那一环） | 默认需要（下载 latest） | 认证对象=用户将拿到的最新产物；期望版本从下载树自读；下载物进沙箱 dl/，不触碰 release-test/ |
| R3 | `run.sh r3` | 工作区 `00-setup` 流水线 01→02(npm)→03(补丁)→04 | npm + nodejs.org | **冷装 20min+ 属正常**，别误判挂死；前置预检真机 glibc 三件套 |
| R4 | `run.sh r4` | 种子旧 runtime → **工作区** `update-dsh.sh -t <tag> -y` 更新机制 | npm registry | `DSH_UPDATE_TAG=<tag>` 换目标（默认 latest；旧名 `DSH_R4_TAG` 兼容）；同版本时打印 note 不断言失败 |
| R5 | `run.sh r5` | 同 R4 但种子=**latest 下载的** runtime、执行其**内置**更新器+补丁（Option A 用户真实路径；打包缺 patch/更新器只有这里红） | npm registry | 钩子期望值按 shipped common.sh 能力派生；种子下载物进沙箱 dl/ |

每个沙箱测试脚本开头清除调用者继承的 `LD_PRELOAD`/`LD_LIBRARY_PATH`/
`NODE_OPTIONS`/`NODE_REPL_EXTERNAL_MODULE`——清单只定义于 `sandbox-lib.sh`
一处（`env_sanitize`），serve.sh 也从这里取。沙箱测的是**产物**，不是调用者
的 shell 环境。若被测 node 启动失败，stderr 会打印并落盘到对应沙箱目录后再 FAIL。

R1/R2 共同断言集：安装退出码 0（install.sh 无残留复制逻辑）、node ELF 解释器
指向 glibc loader 且可直连运行、wrapper 直连 exec 出**期望版本**（r1=pin 的
DSH_VERSION；r2 浮动模式=下载树 package.json 自读）、opener 无参退 2、
symlink+bashrc 注入、**线上运行时未被触碰**（sha256 不同且线上 node 可运行）；
R1 额外校验两份基线资产的 sha256 与 pin 一致，R2 校验 tarball 关键文件齐全
（补丁清单/标记按 tarball 内置 patch-lib.sh 的 `DSH_PATCH_SET` 派生，并核对
shipped lib 已带 marker；另跑 landlock tmpdir 行为探针——marker 条件触发，
旧产物自动跳过，1.2.0+ 产物自动升级为行为级断言）。
R4/R5 共同断言集：npm 重装成功、补丁标记齐全（R4 按工作区 `DSH_PATCH_SET`
全集；R5 按 shipped patch-lib.sh 能力派生，两段式旧条目回退
`platformLinkDenied`）、landlock tmpdir 行为探针（marker 条件触发：R4 的
工作区集必测；R5 的旧 shipped 集跳过、新 release 起必测——探针真实 import
被测树的 dsh-sandbox-local，断言 workspace-write 授权表含 `os.tmpdir()` 且
read-only 仍只授 `/dev/null`；kernel 级行为归人类实测 serve.sh 清单 3b）、
wrapper/opener/symlink 重写可用、update 钩子按「即将运行的生成器」能力存活、
线上运行时未触碰。

### 1.3 人类实测：沙箱内起 Web 界面（serve.sh）

自动层全绿只是门槛；安装类改动的**最终判定**是沙箱 Web 点检：

```sh
bash .test-install/serve.sh                 # 先跑 §1.2 自动层, 全绿才起服务, 端口 3141
bash .test-install/serve.sh 3099            # 位置参数换端口 (默认 3141, 避开线上 3080)
WITH_CREDS=1 bash .test-install/serve.sh    # 复制线上 ~/.dsh 凭据/设置进沙箱 (见下)
NO_OPEN=1 bash .test-install/serve.sh       # 不自动开浏览器 (agent 冒烟用)
REUSE=1 bash .test-install/serve.sh         # 跳过自动层, 复用沙箱 (仅限网页行为迭代)
```

- 自动层门槛：serve.sh 启动前必跑 `bash .test-install/run.sh r1`，失败即拒绝启动；
  只有明确在做「网页行为迭代」时才可 `REUSE=1` 跳过（跳过时仍会透传一次基线
  一致性检查），安装链路改动禁止跳过；serve 自身的环境清洗也取自
  `sandbox-lib.sh` 的统一清单（历史上窄清单漂移过一次）；
- **工作区补丁集注入**：门槛通过后，serve.sh 会把**工作区** `scripts/patch-lib.sh`
  声明的 `DSH_PATCH_SET` 打到沙箱 work 树上（含 marker 验证 + landlock tmpdir
  行为探针，漂移或探针失败即拒绝启动）——
  基线 tarball pin 的是发版时的补丁集，永远滞后于工作区，不打这步则新补丁在
  沙箱 Web 里无从生效、无从人工实测（教训：曾因此把实测步骤错误指向线上 runtime，
  违反 §1.4）。打的场景与 R4 认证一致（基线种子 × 工作区补丁链）；
- 隔离范围：HOME/TMPDIR/TMP/XDG_{CONFIG,CACHE,STATE}_HOME/DSH_* 全部指向
  沙箱内，`--host 127.0.0.1` 显式指定（serve.sh 由原始浏览器交接实测脚本
  演进而来，端口 3141 沿用历史默认）；
- 启动后打印**人类点检清单**：页面标题 DeepSeek Harness → 建会话发消息 →
  agent 写/读文件落点沙箱 ws/ → 浏览器交接（沙箱 opener 交到 Android 默认浏览器）→
  线上 `~/.dsh` 与 127.0.0.1:3080 不受影响 → Ctrl-C 退出；
- 凭据说明：线上 LLM Key 在 `~/.dsh/.credentials.yaml`（settings.yaml 的
  `apiKeyEnv` 只是引用名，值经 credentials 域读取）。沙箱默认**无**此凭据，
  发消息会提示缺 API Key——属预期；要实测聊天必须 `WITH_CREDS=1`
  （只读复制 `.credentials.yaml` + `settings.yaml` 进沙箱，值不打印）
  或在沙箱 UI 手填 Key；未配凭据时该项只能标「未实测」；
- Ctrl-C 退出后沙箱保留在 `.test-install/sandbox-run/`，磁盘紧张可
  `bash .test-install/run.sh clean` 清掉全部沙箱（只删 sandbox-*，保留基线、
  路线代码与 baseline.env；发现非白名单残留文件时仅提示不删），自动层重跑自动重建。

### 1.4 沙箱边界（永不可触碰线上环境）

- 沙箱运行期间 `HOME`、`TMPDIR`、`DSH_RUNTIME_DIR`、`DSH_BIN_DIR` 必须
  指向各自沙箱目录之内（R1 `sandbox-run/`、R2 `sandbox-release/`、
  R3 `sandbox-setup/`、R4/R5 共用 `sandbox-update/` 且不可并行）；
- **严禁**改动/删除/重装线上：`~/.local/opt/dsh-termux-runtime/`、
  `~/.local/bin/dsh`、`~/.bashrc`、`~/.dsh`；
- `grun` 在沙箱里用 stub（`exec "$@"` 透传），不得调用真机 grun 去装真环境；
- 磁盘占用：基线 release-test/ ~100MB，每个 sandbox-*/ 解包后 ~0.5GB（R4/R5
  npm 重装、R3 全量 setup 后再加 ~0.1-0.4GB）；清理用
  `bash .test-install/run.sh clean`，重跑任一路线自动重建自己的沙箱。

## 2. 上游 dsh 源码与 GitHub Token

### 上游源码位置

- 上游 DeepSeek Harness 的**完整源码**检出于 `~/vibe-coding/dsh-source`（monorepo：
  CLI 在 `apps/cli`，其命令行定义在 `apps/cli/src/args.ts`；各包在 `packages/`）。
  本项目交付的一切断言（例如「上游没有 update 子命令」）以这份源码为准；
- **npm 包 ≠ 源码**：设备上运行的是 npm 编译产物
  （`~/.local/opt/dsh-termux-runtime/work/node_modules/@deepseek-ai/`），打补丁、
  验 marker 都针对它——查问题先分清该看哪边；
- 源码树与安装产物是两个独立世界：在本仓库工作时只读引用源码做对照，不构建、
  不改动、不在其中跑本项目的脚本。

### GitHub Token（维护者：获取与使用）

- **存放位置**：`~/.config/dsh-termux/.env`（仓库**外**、gitignored 之外的
  用户配置文件目录；文件权限 600），内容形如 `export GH_TOKEN=…`。
  值**永不打印、永不进提交**，文档/日志只允许出现键名 `GH_TOKEN`；
- **装载**：不自动加载；需要时手动 `source ~/.config/dsh-termux/.env`
  （或 `set -a; . ~/.config/dsh-termux/.env; set +a`）；
- **获取**：GitHub → Settings → Developer settings → Personal access tokens →
  Tokens (classic) 新建，勾选 `repo`（或 fine-grained：仅本仓库 + Contents
  读写）；生成后一次性复制进 `.env`；
- **使用场景**：
  - 手动调 GitHub API / 发布 release：`curl -H "Authorization: Bearer $GH_TOKEN" …`
    （本机未装 `gh` CLI，用 curl 即可）；
  - CI 的 `.github/workflows/release.yml:42` 用的是 Actions **自动注入**的
    `secrets.GITHUB_TOKEN`，与本地 `.env` 无关；
  - 下载**公开** release 发布物（§1.1 的 wget）**不需要** token；
  - `~/.config/dsh-termux/.env` 与 `~/.profile` 里的 `https_proxy` 互不影响，
    两者按需分别装载。

## 3. Termux 环境识别与目录禁忌

在 Termux 里工作的第一原则：先确认自己是不是在 Termux 环境中；如果是，
就**不要**访问 Android 禁止访问的目录（最典型的是系统根 `/tmp`）。

- **如何检查是否在 Termux**（满足其一即可）：
  - `$PREFIX` 已导出且 `$PREFIX/bin` 存在（Termux 下
    `PREFIX=/data/data/com.termux/files/usr`）；
  - `uname -o` 输出 `Android`；
- **若在 Termux，禁止访问 Android 禁止目录（如 `/tmp`）**：
  - 直接读写多为 `Permission denied`；部分路径会被 SELinux/沙箱**静默拒绝**，
    症状像「命令没跑/没生效」而不是报错，极易误判为代码问题；
  - Termux 自己的临时目录是 `$PREFIX/tmp`
    （即 `/data/data/com.termux/files/usr/tmp`），**不是** `/tmp`；
    但该目录同样可能因权限/沙箱策略被拒（实测 `mktemp` 落在其中会被拒）；
  - **规律**：临时文件/测试目录一律放「工作区/沙箱内」。本仓库为
    `.test-install/sandbox-*/tmp`；`TMPDIR`/`TMP` 由 sandbox-lib.sh 的
    隔离导出与 serve.sh 强制覆盖到沙箱内，不依赖任何系统 tmp；
  - 脚本里 `mktemp`/`mkdir` 落点必须显式 `cd "$D" || exit 1` 守卫 + 落点确认，
    绝不写死系统路径（教训：无守卫的临时目录测试曾在仓库根目录误覆盖文件）。

## 4. 测试场景矩阵（五条路线，同模式扩展）

沙箱自动层五条路线全覆盖，统一由 `run.sh` 分发、共用 `sandbox-lib.sh` 与
`baseline.env`（详见 §1.2 的路线表）：

| 路线 | 入口 | 测什么（断言失败即 FAIL） |
|---|---|---|
| R1 基础安装 | `run.sh r1` | 工作区 `build/install.sh` × 基线 tarball 解包+接线（每次迭代必跑） |
| R2 发布物 | `run.sh r2` | **下载 latest release** 认证 shipped install.sh + tarball 是否完好（`--pinned` 则测 pin 资产） |
| R3 setup 管线 | `run.sh r3` | 工作区 `00-setup.sh` 01→02(npm 装 dsh)→03(补丁)→04 源码树安装方案（web 跳过） |
| R4 更新链路(工作区更新器) | `run.sh r4` | 种子旧 runtime → 工作区 `scripts/update-dsh.sh -t <tag> -y` 的更新机制 |
| R5 更新链路(tarball 内置更新器) | `run.sh r5` | 种子=latest 下载的 runtime，执行其内置更新器+补丁——Option A 用户真实路径（打包缺件只有这里红） |

交付门槛 = `bash .test-install/run.sh all`（= r1+r2+r4+r5）。新增一条路线的
步骤：在 `routes/` 写驱动+专属断言（source sandbox-lib.sh）、在 `run.sh`
登记映射与 all 列表、在本表与 §1.2 各加一行。

- **补丁链路**：CI 的 patch 检查（对 npm 最新版 apply + boot smoke）已存在，
  本地改动 `scripts/patch-lib.sh` 或 `patches/` 时至少 `bash -n`，
  再按需在隔离 HOME 演练 `scripts/0x-*.sh` 各步骤；R4/R5 的补丁标记断言
  （marker 由 `DSH_PATCH_SET` 三段式条目声明，不再是硬编码单词）同时覆盖
  「补丁对新版本 dsh 仍可重打」，R5 额外覆盖「tarball 打包的补丁与 lib 版本自洽」。

## 5. 各改动类型的测试门槛

| 改动类型 | agent 必做（自动层） | 人类实测（最终判定，必做） |
|---|---|---|
| install.sh / common.sh / wrapper / opener | bash -n + `run.sh r1`（改动 wrapper 生成器时另跑 r4/r5 验钩子存活） | 沙箱点检 `bash .test-install/run.sh serve` 或 `serve.sh`（§1.3 清单逐项确认）；发布前建议再真机完整安装一次 |
| patch-lib.sh / patches/ | bash -n + CI patch 检查 +（改 patches 时）`run.sh r4` + `run.sh r5` | 真机 `dsh web` 会话保存（write 工具）+ 浏览器交接 |
| update-dsh.sh | bash -n + `run.sh r4 r5`（二选一不够：两者执行物不同） | 真机执行一次真实更新并验收 |
| 00-setup.sh / 01-04 管线 | bash -n + `run.sh r3` | 真机完整跑一次 `00-setup.sh -y` 并验收 dsh web |
| CI / release 工作流（含 build-runtime.sh 打包） | 本地语法/逻辑走查 + `run.sh r2`（默认即下载最新 release 认证） | 真机跑一次 release 产物安装验收 |
| 纯文档 | 链接/锚点核对 | 无强制，但措辞类改动仍建议人类过目 |

## 6. 交付与提交流程

1. 自动层全绿（`bash -n` / CI / 沙箱）后，把改动交给人类审阅；
2. 审阅附件必须包含**最小手动实测步骤**，示例模板：

   ```sh
   # 1) 完整安装（真机）
   bash install.sh -y
   #    预期: … ; 检查: dsh --version; dsh web --port 3080 并在浏览器打开
   # 2) 更新（如涉及）
   bash ~/.local/opt/dsh-termux-runtime/scripts/update-dsh.sh -t next -y
   #    检查: 版本变化、dsh web 正常
   # 3) 回滚/清理（如提供）
   ```

3. 人类复核并实测确认后，才允许提交 / 合并 / 发布；
   安装类改动以 §1.3 serve.sh 的清单逐项回复作为实测凭据，缺项必须标「未实测」；
4. 提交信息用英文、conventional 前缀（refactor/fix/feat/docs/ci/housekeeping）。