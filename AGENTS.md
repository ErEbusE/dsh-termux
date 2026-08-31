# AGENTS.md — dsh-termux 开发测试协议

本文件指导在本仓库工作的 AI 代理如何测试改动（操作细节见
`.test-install/README.md`）。已纳入 git 跟踪，随仓库演进。改动仓库代码前先读本文件。

## 0. 铁律：agent 的测试 ≠ 通过测试

> 禁止默认「agent 跑一下无头/冒烟测试（语法检查、沙箱安装、CI 绿）
> 就算通过测试」。

- agent 侧的任何测试（`bash -n`、CI、§1 沙箱安装）只是**必要不充分**的
  一层自动防护；
- 涉及安装、更新、补丁、浏览器交接等任何**会落到真机行为**的改动，最终
  都必须由**人类在真实 Termux 设备上实际使用和测试**，agent 不得代替判定;
- 每次把改动交付人类审阅时，必须在**会话中**交付**最小、可照抄的手动实测
  步骤**（命令、预期结果、逐步检查点）——步骤与实测结果都留在会话里，
  **不写入 PR**；在人类明确回复「通过/已验证」之前，
  状态一律是**「待人类实测」**——不得宣称测试通过、不得合并、不得发布 release；
- 若改动确实无法真机验证（如无设备），必须如实标注「未实测」，
  绝不能假装通过，也不能把 agent 跑过的自动测试冒充为人类实测结果。

## 1. 沙箱测试方案（.test-install/）

测试体系的**操作细节**（路线表、断言分级、baseline 管理、serve.sh 用法、
沙箱边界、历史教训、新增路线步骤）单点住在 **`.test-install/README.md`**——
跑测试或改测试体系前必读。这里只留每个会话都需要的不变量：

- **唯一入口**：`bash .test-install/run.sh all`（= r1+r2+r4+r5+r6；`--with-r3`
  追加 r3）；日常迭代单跑 `run.sh r1`；忘了命令敲 `run.sh help`；
- **人类实测**：`bash .test-install/serve.sh`（自动层门槛全绿才起沙箱 Web，
  端口 3141；`WITH_CREDS=1` 带凭据实测聊天）——安装/更新类改动的**最终判定**
  是 serve.sh 点检清单逐项确认，缺项必须标「未实测」；
  **人类实测同样必须经 serve.sh 的沙箱环境**，交付的实测步骤绝不允许指向
  本地正在运行的 dsh runtime/`~/.dsh`/`~/.bashrc`（教训：曾两次把实测清单写成直改本地正在运行的安装，
  被人肉纠正）；对本地正在运行的 dsh runtime 的升级只作为最后一步，执行的是沙箱里已验证过的产物；
- **沙箱边界（永不可触碰本地正在运行的 dsh runtime）**：沙箱期间 HOME/TMPDIR/DSH_* 必须指向沙箱内；
  严禁改动/删除/重装本地正在运行的 `~/.local/opt/dsh-termux-runtime/`、`~/.local/bin/dsh`、
  `~/.bashrc`、`~/.dsh`；`grun` 用 stub；
- **判定标准**：任何断言失败即 FAIL，禁止「只跑个大概」；每条路线结束打印
  `== [rN] done: N ok ==` 与集中 WARN；r4 与 r5 共用沙箱目录，**不可并行**；
- **基线纪律**：基线事实只在 `baseline.env`（已入 git），改 pin 只走
  `run.sh baseline set <tag|latest>`，绝不手编；发版后必须回来 re-pin
  （WARN 会持续提醒）。机械 re-pin 是**纯派生数据**（工具写出、哈希现算、
  无编辑内容；发布动作本身即为 pin 内容的批准）：r2/r5 全绿后由 agent
  **直推 main 即可，无需 PR**（先例 `370d5bc`、`1e8ffce`）；
- 测试代码已纳入版本管理（代码跟踪、数据 ignore）——改动测试体系与改动
  仓库代码同等对待：同 PR、同 review。唯一例外是上面的机械 baseline
  re-pin；其余任何 `.test-install` 改动（路线代码、断言、沙箱边界——凡含
  判断内容者）不得享受该豁免。


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
  - CI 的 `.github/workflows/release.yml` 里那行 `GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}`
    用的是 Actions **自动注入**的令牌，与本地 `.env` 无关（按键名 grep，不钉行号——
    行号会随同文件的增删而腐烂：本行曾从 42 改到 47，实际已是 50）；
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

## 4. 测试场景矩阵（六条路线）

沙箱自动层六条路线全覆盖，统一由 `run.sh` 分发、共用 `sandbox-lib.sh` 与
`baseline.env`（路线表与断言细节见 `.test-install/README.md`）：

| 路线 | 入口 | 测什么（断言失败即 FAIL） |
|---|---|---|
| R1 基础安装 | `run.sh r1` | 工作区 `build/install.sh` × 基线 tarball 解包+接线（每次迭代必跑） |
| R2 发布物 | `run.sh r2` | **下载 latest release** 认证 shipped install.sh + tarball 是否完好（`--pinned` 则测 pin 资产） |
| R3 setup 管线 | `run.sh r3` | 工作区 `00-setup.sh` 01→02(npm 装 dsh)→03(补丁)→04 源码树安装方案（web 跳过） |
| R4 更新链路(工作区更新器) | `run.sh r4` | 种子旧 runtime → 工作区 `scripts/update-dsh.sh -t <tag> -y` 的更新机制 |
| R5 更新链路(tarball 内置更新器) | `run.sh r5` | 种子=latest 下载的 runtime，执行其内置更新器+补丁——Option A 用户真实路径（打包缺件只有这里红；tarball 携带 VERSION 时加跑 --self 自更新链路） |
| R6 更新链路(工作区更新器 --self) | `run.sh r6` | 工作区更新器的 self_update 全链路：显式 `--self -y`（播种假旧 VERSION+弄脏补丁 → 断言「旧→新项目版本显示」+VERSION 替换+npm 完成）与 re-exec 后哨兵行为（白盒模拟：答 n 中止时的「补丁未应用」NOTE 仅当补丁集真变化；-y 下明示在、停止提示被抑制）——r4 种子与 latest 一致时该路径天然不触发、r5 1b 执行的是旧 shipped 更新器，新代码此处零覆盖 |

交付门槛 = `bash .test-install/run.sh all`（= r1+r2+r4+r5+r6）。新增一条路线的
步骤见 `.test-install/README.md`（routes/ 驱动 + run.sh 登记 + README 路线表）。

- **CI 分工（两个工作流，按「改动能破坏什么」分流，不是按提交类型分）**：
  - `.github/workflows/verify.yml` —— 每个 PR / push main 必跑、不联网装包、
    目标 1 分钟内出结果：全部受跟踪 `*.sh` 的 `bash -n` + ShellCheck
    （当前门槛 `-S error`，清干净 warning 后再收紧）、`DSH_PATCH_SET` 与
    `patches/` 的静态一致性、wrapper/opener 生成器、`install.sh` 委派守卫、
    `update-dsh.sh` 帮助窗口契约、`.test-install/run.sh` 入口与路线登记、
    文档相对链接/锚点（`.github/scripts/check-doc-links.py`）；
  - `.github/workflows/patch-check.yml` —— 只在 `patches/`、`scripts/patch-lib.sh`、
    `NODE_VERSION` 变化时，或每晚 cron，或手动 dispatch 时跑：npm 装 dsh →
    套补丁 → 校验 marker → 回归守卫 → boot smoke（~16min，其中 npm 占 98%）。
    **上游漂移是时间的函数、不是 PR 的函数**，所以它是定时哨兵而非 PR 门槛；
    改补丁的 PR 会自动带上它，需要临时验证别的 npm spec 就用 Run workflow；
  - 若日后给 main 开分支保护：把 `verify / static` 设为 required，
    **不要**把 `patch-check` 设为 required（路径过滤不运行时会永久 pending）；
  - 两者都**不**替代 §1 沙箱与 §0 真机实测。
- **补丁链路**：CI 的 patch 检查（对 npm 最新版 apply + boot smoke）见上，
  本地改动 `scripts/patch-lib.sh` 或 `patches/` 时至少 `bash -n`，
  再按需在隔离 HOME 演练 `scripts/0x-*.sh` 各步骤；R4/R5 的补丁标记断言
  （marker 由 `DSH_PATCH_SET` 三段式条目声明，不再是硬编码单词）同时覆盖
  「补丁对新版本 dsh 仍可重打」，R5 额外覆盖「tarball 打包的补丁与 lib 版本自洽」。

## 5. 各改动类型的测试门槛

| 改动类型 | agent 必做（自动层） | 人类实测（最终判定，必做） |
|---|---|---|
| install.sh / common.sh / wrapper / opener | bash -n + shellcheck + `run.sh r1`（改动 wrapper 生成器时另跑 r4/r5 验钩子存活） | 沙箱点检 `bash .test-install/serve.sh`（点检清单见其启动输出与 `.test-install/README.md`）；发布前建议再真机完整安装一次 |
| patch-lib.sh / patches/ | bash -n + shellcheck + CI（verify 的静态登记表检查 + 自动触发的 patch-check）+（改 patches 时）`run.sh r4` + `run.sh r5` | 真机 `dsh web` 会话保存（write 工具）+ 浏览器交接 |
| update-dsh.sh | bash -n + shellcheck（CI 另查帮助窗口契约）+ `run.sh r4 r5 r6`（三选任缺不可：三者执行物不同——r4 普通路径 / r5 shipped / r6 --self 全链路+哨兵） | 真机执行一次真实更新并验收 |
| 00-setup.sh / 01-04 管线 | bash -n + shellcheck + `run.sh r3` | 真机完整跑一次 `00-setup.sh -y` 并验收 dsh web |
| .test-install/ 测试体系 | bash -n + shellcheck + CI verify（入口与路线登记）+ 实跑受影响路线 | 视被测路线而定；改测试体系本身不产生新的真机项 |
| CI / release 工作流（含 build-runtime.sh 打包） | 本地语法/逻辑走查 + `run.sh r2`（默认即下载最新 release 认证）+ 在 PR 上**实际看运行**（该跑的跑了、不该跑的没跑） | 真机跑一次 release 产物安装验收（仅当改动影响产物内容） |
| 纯文档 | `python3 .github/scripts/check-doc-links.py`（CI 同款）+ 链接/锚点核对 | 无强制，但措辞类改动仍建议人类过目 |

## 6. 交付与提交流程

1. 自动层全绿（`bash -n` / CI / 沙箱）后，把改动交给人类审阅；
2. 实测步骤在**会话中**交付指导（步骤与实测结果都不进 PR 正文），形如：

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
   安装类改动以 serve.sh 点检清单逐项回复作为实测凭据，缺项必须标「未实测」；
   合并时把实测凭据写成 `Tested-by:` trailer 带进合并（或末位）提交——
   git 历史即永久留痕，PR 正文保持干净（`git log --grep='^Tested-by:'` 可检索），
   形如 `Tested-by: ErEbusE [on-device: full gate + serve.sh checklist @9a75ac2, 2026-08-31 15:40+08:00]`——
   `@哈希` 为被测分支 tip（与 `git show <merge>^2` 互为印证），时刻取本地时间含时区
   （时刻 `date '+%F %R%:z'`、哈希 `git rev-parse --short`；仓库内一步组装：
   `bash .test-install/tb.sh "<实测覆盖面一句话，如 'r6 + full gate'>" [tree-ish]`，
   更多示例见 `.test-install/README.md`「合并留痕」）；
4. 小文档直推仅限「PR 合并后的收尾修正」量级：**个别文件、数行以内**、
   不触及任何代码行为，且**不触碰 `.test-install/` 内的代码文件**（其中的
   注释/文案字符串随代码同 review）；跨文件的成体系文档修改（如 `b7c759c`
   的全仓术语清扫）仍走分支+PR。前提：内容已在会话中经人类确认；无需
   Tested-by（无可实测项）——先例 `1c9c869`、`2f35f26`；
5. 提交信息用英文、conventional 前缀（refactor/fix/feat/docs/ci/housekeeping）；
6. 发版 bump（`VERSION` 变更）随触发本次发版的 PR/分支同车（无需单独 PR），
   但必须**独立为一个只改 `VERSION` 一个文件的提交**，不与任何代码/文档改动
   混入同一提交——revert、审计与 release 触发点因此各自干净（教训：PR #12
   曾把 bump 混进 fix 提交）。