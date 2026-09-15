# AGENTS.md — dsh-termux 开发测试协议

本文件是**执行边界与证据协议**：每次会话都需要的**不变量**。测试操作细节（命令、case 清单、serve 用法、新增 case 步骤、shebang 契约、token 怎么建）单点住在 [.test-install/README.md](.test-install/README.md)，**跑测试或改测试体系前必读**；进度在 [.test-install/STATUS.md](.test-install/STATUS.md)，决策的"为什么"在 [.test-install/DECISIONS.md](.test-install/DECISIONS.md)。改仓库代码前先读本文件。

**单点描述原则**：同一件事只在一处写"权威版"，别处只留指针。本文因此**不复述** case 清单（事实源是 `.test-install/cases/registry.tsv`）、**不复述**命令表（`run.sh help`）、**不复述** CI 逐条分工（`.github/workflows/` 与 [CONTRIBUTING.md](CONTRIBUTING.md)）。

## 0. 铁律：agent 的测试 ≠ 通过测试

> 禁止默认「agent 跑一下无头/冒烟测试（语法检查、沙箱安装、CI 绿）就算通过测试」。

- agent 侧的任何测试（`bash -n`、ShellCheck、CI、沙箱 case）是**必要不充分**的一层自动防护。自动测试 PASS 是**有效结果**，但**只对它报告的范围负责**；设备上的自动运行可称 *on-device automated*，**只有真人操作证据才是 human verified**。
- 涉及安装、更新、补丁、浏览器交接等任何**会落到真机行为**的改动，最终必须由**人类在真实 Termux 设备上实际使用和测试**，agent 不得代替判定。
- 交付时必须在**会话中**给出**最小、可照抄的手动实测步骤**（命令、预期、逐步检查点）——步骤与结果都留在会话里，**不写入 PR**。人类明确回复「通过/已验证」之前，状态一律是**「待人类实测」**：不得宣称通过、不得合并、不得发布 release、不得写最终 `Tested-by`。
- 确实无法真机验证时如实标注「未实测」——绝不假装通过，也绝不把 agent 的自动测试冒充为人类实测结果。交付须满足本次风险契约要求的证据，**agent 不得自行豁免**。

## 1. 测试体系的边界与纪律

**唯一交付检查入口**是 `bash .test-install/run.sh verify`（`check` 是快集、`full` 是诊断，**都不授予交付资格**）。

- **沙箱边界（永不可触碰本地正在运行的 dsh runtime）**：沙箱期间 `HOME`/`TMPDIR`/`DSH_*` 必须指向沙箱内；**严禁**改动/删除/重装 `~/.local/opt/dsh-termux-runtime/`、`~/.local/bin/dsh`、`~/.bashrc`、`~/.dsh`；`grun` 用 stub。临时文件一律落工作区/沙箱内——Termux 下**禁访系统 `/tmp`**。判定标准：**任何断言失败即 FAIL**，禁止「只跑个大概」。
- **人工签认授权**：带人工项的 case 走 `verify`（开轮次 + 冻结对象）→ `serve.sh --round`（人在浏览器里逐项实测）→ `run.sh finalize <轮次id> --observed <对象id>`。**人类实测必须经 serve.sh 的沙箱环境**，agent 交付的实测步骤**绝不允许**指向本地正在运行的 dsh runtime / `~/.dsh` / `~/.bashrc`（教训：曾两次把清单写成直改本地正在运行的安装，被人肉纠正）；对本地 runtime 的升级只作为最后一步，执行的是沙箱里**已验证过**的产物。**签认绑定对象，不绑定清单名**，缺项必须标「未实测」。
- **证据须绑定被测对象**：测试结论不得伪造；`Tested-by` 只对**收尾后的精确提交与冻结对象**有效，改动了受验内容就得重测。
- **维护者工具**：可复用的本地工具一律放 `.test-install/tools/`——**整目录白名单**，放进来即自动纳入版本管理；一次性脚本不留存、不散落在 `.test-install/` 根目录。
- **种子纪律**：基线事实只在 `seeds/<名>.env`（已入 git），改 pin 只走 `run.sh seed set`，**绝不手编**；**旧种子保留**，不因新发版淘汰（ADR-004 已撤销"发版后必须回来 re-pin"与"机械 re-pin 可直推 main"两条规则）。改 pin 改变的是"测试覆盖哪些版本"的判断，**与代码改动同走 PR review**（哈希仍由工具现算）。
- **测试代码同等 review**：测试体系已纳入版本管理（代码跟踪、数据 ignore）；改动它与改动仓库代码**同等对待——同 PR、同 review，没有例外**。**测试政策自身的改动必须显式 review。**

## 2. 上游源码、npm 产物与凭据纪律

- 上游 DeepSeek Harness 的**完整源码**检出于 `~/vibe-coding/dsh-source`（monorepo：CLI 在 `apps/cli`，命令行定义在 `apps/cli/src/args.ts`）。本项目交付的一切断言（例如「上游没有 update 子命令」）以这份源码为准。**源码树与安装产物是两个独立世界**：设备上运行的是 npm 编译产物（`~/.local/opt/dsh-termux-runtime/work/node_modules/@deepseek-ai/`），打补丁、验 marker 都针对它——查问题先分清该看哪边；在本仓库工作时只读引用源码做对照，不构建、不改动、不在其中跑本项目的脚本。
- **凭据纪律**：token 存 `~/.config/dsh-termux/.env`（仓库**外**，权限 600），值**永不打印、永不进提交**——文档与日志只允许出现键名 `GH_TOKEN`；不自动加载，需要时手动 source。
- **三层分工（按消费者分，不是二选一）**：① **维护者会话（人或 agent）**统一走 `gh` CLI——它是唯一界面，自动读取环境里的 `GH_TOKEN`。**不要手写 GitHub API 调用**：裸 API 的 302 签名 URL 会拒绝被转发的 `Authorization`，引号与分页也要自己兜。② **设备侧 / 发布物脚本**（`install.sh`、`update-dsh.sh`、`patch-lib.sh` 等）**禁止**依赖 `gh`，只用 `curl`/`wget` 打公开端点——下载公开 release 发布物**不需要** token。③ **CI** 里的 `GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}` 是 Actions **自动注入**的，与本地 `.env` 无关（**按键名 grep，不钉行号**——行号会随同文件增删而腐烂）。

## 3. Termux 环境识别与目录边界

在 Termux 里工作的第一原则：先确认自己是不是在 Termux 环境中；如果是，就**不要**访问 Android 禁止访问的目录（最典型的是系统根 `/tmp`）。**如何检查**（满足其一即可）：`$PREFIX` 已导出且 `$PREFIX/bin` 存在（Termux 下 `PREFIX=/data/data/com.termux/files/usr`）；或 `uname -o` 输出 `Android`。

- 直接读写禁用目录多为 `Permission denied`；部分路径会被 SELinux/沙箱**静默拒绝**，症状像「命令没跑/没生效」而不是报错，极易误判为代码问题。Termux 的临时目录是 `$PREFIX/tmp`，**不是** `/tmp`；要用就写 **`$TMPDIR`**，不要写死路径。
- **纪律**：测试自己造的临时文件/沙箱目录一律放「工作区/沙箱内」。`TMPDIR`/`TMP` 由 `lib/sandbox.sh` 的隔离导出与 `serve.sh` 强制覆盖到沙箱内，**不依赖任何系统 tmp**——理由从"写不进去"变成"能写也不该写"：这是隔离要求（可复现、可清理、不污染用户环境），不是权限问题。脚本里 `mktemp`/`mkdir` 落点必须显式 `cd "$D" || exit 1` 守卫 + 落点确认（教训：无守卫的临时目录测试曾在仓库根目录误覆盖文件）。

## 4. CI：不许动的地方与为什么

- **`verify.yml`（`static`）= 唯一的 required check**：每个 PR / push main 必跑、**不联网装包**、目标 1 分钟内出结果（含 `bash -n` + ShellCheck、补丁注册表静态一致性、生成器契约、测试体系入口与清单完整性、**七个冒烟脚本**、文档链接/锚点）。
- **路径/条件过滤的工作流绝不能设成 required**——不运行时会永久 pending（`patch-check`、`pre-release`、`candidate-artifact` 都属此类）。
- **ShellCheck 版本偏差是真的**：runner 自带 0.9.0、Termux 是 0.11.0，两者发现集不同——**本地绿不等于 CI 绿，以 CI 为准**，步骤里打印的 version 行就是用来一眼归因的。
- **刻意没有 cron**：定时轮询无论上游动没动都要占一条运行记录，而它们防的失败很轻——`update-dsh.sh` 与 `00-setup.sh` 在补丁打不上时都会响亮停下，没人会拿到坏安装，维护者只是「下次更新时才知道」；「跟随上游」只能是轮询，而 6 小时一次 ≈ 120 条/月、约 87% 只是在记录「上游没发版」。**人**可以订阅上游 release 代替它。
- **候选产物 workflow** 复用发布**同一份**打包代码，**不发版、不改 pin、不写 release**，`contents: read`。**第一次运行必须由 PR 事件产生**（workflow 注册/可发现的前提）；此后 `gh workflow run` 对**未合并**分支同样可用。
- 它们**都不替代** §1 的沙箱与 §0 的真机实测。

## 5. 各改动类型的测试门槛

**自动层必做项不在这里手列**——`run.sh verify` 按 `registry.tsv` 的 `changes` glob **从改动范围派生**必需 case（"派生，不是手抄"的同一原则；旧文那张按改动类型手写的命令表已经烂掉过一次）。改动类型的**真值**也在 registry 的 `changes` 列：改哪个文件会影响哪些 case，看那一列。

CI 与沙箱**覆盖不到、只能人做**的部分：

| 改动类型 | 人类实测（最终判定，必做） |
|---|---|
| 安装 / 更新 / 补丁 / 包装脚本 | 走 §1 的 `verify → serve.sh → finalize` 闭环，按该轮打印的清单逐项确认 |
| `00-setup.sh` 与 01–04 管线 | 真机完整跑一次 `00-setup.sh -y` 并验收 `dsh web` |
| CI / release 工作流（含打包） | 在 PR 上**实际看运行**（该跑的跑了、不该跑的没跑）；改动影响产物内容时另做真机安装验收 |
| 纯文档 | 无强制；`python3 .github/scripts/check-doc-links.py`（CI 同款）+ 链接/锚点核对；措辞类改动仍建议人类过目 |

**纯测试体系改动不自动增加人工项，但不得使已有人工证据失效。**

## 6. 交付与提交流程

1. 自动层全绿后，把改动交给人类审阅；实测步骤按 §0 在**会话中**交付（不进 PR 正文）。
2. **工作提交与交付是两件事**（ADR-007 修正了本节此前的措辞「人类确认后才允许提交」）：**允许**产生并追加**工作提交**，也允许把主题分支推给远程供 review/备份——这**不**等于验收。人类复核并实测确认**之前**：不得宣称测试通过、**不得合并、不得发布 release**、**不得**写入最终的 `Tested-by` 验收凭据；交付结论一律停在「待人类实测」。该许可放宽的只是「能不能留下提交身份」，**完全没有放宽「谁有权判定通过」**。
3. **合并留痕（`Tested-by`）**：人类实测确认后，把实测凭据**用工具**写成 trailer 带进合并（或末位）提交——git 历史即永久台账（`git log --grep='^Tested-by:'` 可检索），PR 正文保持干净。`bash .test-install/tools/tb.sh "<范围>" [tree-ish]` 生成，合并动作用 `bash .test-install/tools/pr-merge.sh <PR号> "<范围>"`（默认 dry-run，`--yes` 才执行）——**手拼 trailer 视为流程错误**。**没有真机面**的改动（纯 CI / 纯工作流）用 `tb.sh --review`，标签变 `review`、凭据是审阅 + CI 绿；**能落到设备上的改动一律用默认 `on-device`**——用 review 蒙混等同于 §0 禁止的「拿自动测试冒充实测」。格式与示例见 README 的「合并留痕」。
4. **小文档直推**仅限「PR 合并后的收尾修正」量级：**个别文件、数行以内**、不触及任何代码行为，且**不触碰 `.test-install/` 内的代码文件**（其中的注释/文案字符串随代码同 review）；跨文件的成体系文档修改仍走分支+PR。前提：内容已在会话中经人类确认；无需 `Tested-by`（无可实测项）。
5. 提交信息用**英文**、conventional 前缀（feat/fix/refactor/docs/ci/housekeeping）。
6. 发版 bump（`VERSION` 变更）随触发本次发版的 PR/分支同车（无需单独 PR），但必须**独立为一个只改 `VERSION` 一个文件的提交**，不与任何代码/文档改动混入同一提交——revert、审计与 release 触发点因此各自干净（教训：PR #12 曾把 bump 混进 fix 提交）。
