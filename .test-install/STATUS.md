# STATUS.md — dsh-termux 测试体系重构：项目现状

> 本文件是**进度台账**，供上下文压缩/换人后接续。**决策的"为什么"不在这里**——
> 那是 `DECISIONS.md`（**ADR-001..013**、实查更正 C1–C5、附录 A 的迁移映射）。
> 规矩：改**进度**只改本文件；改**决定**只改 `DECISIONS.md`（两者都过 PR review）。
> 操作手册在 `README.md`；场景矩阵的**唯一事实源**是 `cases/registry.tsv`。

---

## 当前状态（RESUME HERE）

> 进度台账，供上下文压缩/换人后接续。改动进度时同步更新本节。
> 详细的"为什么"在 `DECISIONS.md` 的 ADR 里；本节只留**接续所必需的事实**。

### 现在在哪

- 分支 **`refactor/test-system`** 已推送、工作树干净、与 origin 同步；**PR #38**
  （→ `main`；`auto-merge` 关闭）。**⚠️ 它已不是 draft**：维护者于 2026-09-15 15:55 主动
  点了 "ready for review"（timeline 有 `ready_for_review`、无 `convert_to_draft`）。
  **状态以 GitHub 为准，不要照抄本文件**（`gh pr view 38 --json isDraft,state`）。
  仍然成立且**没变**的约束：未合并、无 auto-merge、未发版、未 bump、未改 pin、
  未写最终 `Tested-by`。**不要**把"曾经写着 draft"当成现在的事实。
- **CI**：**四项都要现查 `gh pr checks 38`，别引用本文件**——`patch-check`／`candidate-artifact`
  的路径过滤看的是**整个 PR diff**，所以任何一次 push（哪怕纯文档）都会重跑那条 ~7 分钟的
  `build`。**"最近一次全绿是某提交"这种写法每推一次就过期一次，故不再记**。已知的稳定事实：
  删掉原生件步骤之后 `patches` 与 `build` 都真跑过并绿，等于顺带证明**支持版本走 npm 路径
  不需要编译原生件**，且那三处 workflow 编辑没有破坏构建。
- **矩阵现状**：`cases/registry.tsv` **18 条登记行 ＝ 18 条都有 executor**（`validate
  --strict-executors` 通过）。盘上 `cases/*.sh` 实测也是 **18 个**；登记层面的覆盖缺口
  **已全部消除**（末三条：两条 `candidate-artifact`、7f、11d）。
  **18 条 executor 全部真机跑过**（详见「已实测通过」表）。
- **自动层入口** `run.sh`：`list | validate | check | verify | full | finalize | seed | clean`
  （旧 `r1..r6`/`all` 已不存在）。**人类实测入口** `serve.sh`：`--list | --round <轮次id> |
  --sandbox <名>`；开关一律 `--flag`，旧的环境变量写法（`WITH_CREDS=` 等）被**硬拒绝**。
- **当前位置**：第 1–7 项（含 **7f 缺口已补齐**）、11 的 ①②、11b、11c、**11d**、第 9 项
  都已落地；**第 10 项（文档重生成）也已落地**，**下一步是第 12 项交付**。
- **11 ①② / 11b / 11c 都已落地**（细节与"为什么"在 **ADR-001 落地记录**，此处只留结论）：
  `patch-matrix.sh` 改锚到 `lib/patchset.sh`＋`seeds/*.env` 后，`routes/`／`sandbox-lib.sh`／
  `baseline.env`／`release-test/` 全部删除（`.gitignore` 白名单与失效引用同批清理，
  附录 A 的映射是唯一删除依据）；原生件机件（五个函数、三个调用点、
  `.github/actions/build-natives/`、三个 workflow 的引用）全部下线；下限门禁在
  `update-dsh.sh` 与 `02-install-dsh.sh` 两个入口生效（npm 改写树**之前**解析成一个精确版本）。
- ✅ **11d 已落地**（`69efdf5`）：新增 case `release-install/legacy-tarball`，真机 **22 断言 PASS**。
  **主体选择**：`pre-dsh-0.1.3-alpha.2-g82a5fd6-1.2.8`。原文写的"0.1.3.x／0.1.4.x release"
  **字面上做不到**——稳定渠道**没有任何** 0.1.3.x／0.1.4.x，0.1.4 在任何渠道都不存在，
  唯一的 0.1.3 就是这条 prerelease（ADR-011 明确承认已发布的 prerelease 是有效实例；
  STATUS 原文也没限定 stable，是我先读窄了）。它同时**在实质上**是对的选择：该 tarball
  带**已编译**的 `fs_ext.node`，而 `dsh-0.1.2-rc.1-1.2.8` 的 `fs-ext` 条目数为 **0**——
  0.1.2 根本不需要原生件，不能代表"原生年代"（PATCHES.md 也这么写）。
  **测的是什么**：**当前工作区** `build/install.sh` × 该旧 tarball，在隔离 prefix 里用
  该产物**自带的** `scripts/common.sh` 安装，结果通过声明的探针；并断言装出来的
  `common.sh` 与产物自带那份**逐字相同**（显式的 no-overlay 对照）。
  **可证伪点**：安装器将来若要求一个旧 helper 没有的函数/改签名，或解包/ELF 接线坏掉，
  这条会**红**（另有反证：传错 `--release-tag` → UNMET；缺函数 → 检出）。
  **它不主张什么（已写进 case-facts，别读强）**：**不是**"退役原生件机件"的因果验证——
  被删的代码**不在**这条执行路径上（`install.sh` 从未调用过它，只有 npm 侧的
  `02`/`update` 与 `build-runtime` 调用过），所以删它在这条路径上**没有可观测差异**；
  也不覆盖 npm 路径、低于下限的 npm、`--self`、机件刷新、升级、其余历史版本。
  原生产物探针只证明**可加载**（`require` 成功且导出 `flock`），**不**证明 flock 语义。
  **取证方式**：`bash .test-install/run.sh full --release-tag pre-dsh-0.1.3-alpha.2-g82a5fd6-1.2.8 -c release-install/legacy-tarball`
  （实例不符会记 UNMET，不会静默测别的对象）。人工清单 `serve-legacy` 已登记。
- ✅ **第 10 项已落地**：`AGENTS.md` 重写为 **71 行**的"执行边界与证据协议"（保留 §0–§6 编号
  ——这些编号被 `tools/tb.sh`、`tools/pr-merge.sh`、`lib/sandbox.sh`、`verify.yml`、`PATCHES.md`
  等**按名引用**，改了编号就会变成静默的错指针）；`.test-install/README.md` 重写为操作
  手册。两文件都落在 ADR-007 的行数预算内。**原则是单点描述**：AGENTS 不再复述 case 清单、命令表
  与 CI 逐条分工，只留不变量与指针。同批清理的**过期事实**（都属"下一个人照它会得出错结论"）：
  两个 README 的"六条路线"、`CONTRIBUTING.md` 的"§5 命令拼写仍待重写"与**"未合并前无法
  dispatch"**（已被 run 35004183105 实测推翻）、`PATCHES.md` 的 R1/R2/R3 行号与对
  `serve.sh` **当前**会 overlay 的陈述、`verify.yml`/`patch-matrix.sh`/`lib/patchset.sh`/
  `dry-run-pinned-rebase.sh` 里同款的"serve.sh 现在还会 overlay"（ADR-010 之后它只启动冻结对象）。
  **§6.3 已与 ADR-007 对齐**（`644785c`）：允许工作提交与推送主题分支，但人类实测前不得宣称
  通过、不得合并/发布、不得写最终 `Tested-by`。

### 进度

| # | 事项 | 状态 |
|---|---|---|
| 1 | 决策记录 ADR-001..**013** + 实查更正 C1–C5 | ✅ |
| 1b | ADR-012：shebang 不是可移植性机制（契约＝显式调用；无字节改动） | ✅ 顾问裁决 |
| 2 | 结果/证据协议内核 `lib/state.sh` | ✅ |
| 3 | case 清单 `cases/registry.tsv`（现 **18 条**，矩阵唯一事实源） | ✅ |
| 3b | 新入口 `run.sh` + 种子管理 | ✅ 冒烟 65（种子存储改内容寻址后 +23） |
| 4 | 隔离与收据（白名单环境 / 全路径线上守卫 / build+test 收据） | ✅ 冒烟 37 |
| 5a | 具名输入解析与冻结（`default-target` + 发布物实例） | ✅ 冒烟 16 |
| 5b | 第一个真 case `dry-run/pristine-npm` | ✅ 23 断言（真机） |
| 6 | 冻结对象 serve（内容身份/载荷边界/漂移/轮次/观察台账/同轮终结 + 两套环境基底） | ✅ 冒烟 67 + 人类实测通过 |
| 7a | 旧断言 → 新 case 映射表（附录 A） | ✅ |
| 7b | 三个行为探针迁入 `lib/probes.sh` 并挂进 case | ✅ 冒烟 21 |
| 7c | 15 个 executor + 机制迁移（L8/L9/L10、ADR-011 记账） | ✅ |
| 7d | 种子 `seeds/stable.env`（`dsh-0.1.5-alpha.1-1.3.0`） | ✅ |
| 7e | 执行覆盖：**18/18 条 executor 真机跑过全 PASS** | ✅ 末几条随第 9/7f/11d 项落地补跑 |
| 7g | `update/support-floor`（11c 新增）首跑 **47 断言全 PASS** | ✅ 真机 |
| 7f | 缺口 case `update/post-install-patch-failure-recovery` **executor 已落地** | ✅ 真机 37 断言 PASS |
| 8 | 真实 `00-setup.sh` 入口 ✅ / wrapper 端到端 ✅ / 下载分支 ✅ / 失败恢复 **两半都已覆盖** | ✅ |
| 9 | 分支候选产物 workflow（`publish=false` + `upload-artifact`，先做行为不变的提取提交） | ✅ 两个提交 + 两条 case 真机 PASS |
| 10 | 文档重生成（AGENTS 60–120 行 / README 150–200 行） | ✅ AGENTS **71** 行 / README **186** 行 |
| 11 | 退役：patch-matrix 改锚 + `routes/`／`sandbox-lib.sh`／`baseline.env`／`release-test/` | ✅ ①② 已落地 |
| 11b | ADR-001 原生件机件下线（生产脚本 + CI action + case 断言 + 文档） | ✅ 独立 `refactor:` 提交 |
| 11c | 更新目标下限检查（两个入口 + 拒绝文案 + `update/support-floor` case） | ✅ 真机 47 断言 PASS |
| 11d | 旧 tarball 安装的隔离回归（ADR-001 保留路径） | ✅ `release-install/legacy-tarball` 真机 22 断言 PASS |
| 12 | 交付：冻结最终提交与对象 → 人类同轮实测/`finalize` → `Tested-by` → 合并 | ⏳ 依赖 10；人类那轮须覆盖**退役后的候选产物**、`serve-floor` 与 `serve-legacy` |

### 第 7 项已完成（7a/7b/7c）——细节在 `DECISIONS.md` 附录 A 与下面的 7c 落地记录表

- **7a** 附录 A：52 个断言组＋14 项公共能力＋3 个探针逐条写明"谁继承了它、还缺什么"。
- **7b** `lib/probes.sh`：三个探针 + 聚合入口，**触发 marker 按补丁目标 rel 从消费的注册表派生**
  （旧体系写死串的 H2 缺陷不再存在）；跳过 = 可见 n/a 且进 case-facts，声明了却缺 marker = **FAIL**。
- **7c** executor + 机制迁移（L8/L9/L10、ADR-011 记账）。当时的"缺口 case"（有登记无
  executor）**已在 7f 补齐**，矩阵现为 **18 条登记行 ＝ 18 条都有 executor**。


### 当前执行顺序

**已完成**：11 ①②（`24a63bf`／`ab334a4`）→ 11b（`60c9f38`）→ 11c（`d8af293`）
→ 11d（`69efdf5`）→ 7f（`a2d3a64`）→ 第 9 项（`fc433d6` 提取／`9680535` workflow／
`d6d070d` 首跑缺陷修复／`8439c9f` 凭据加固／`efca774` 产物绑定工具）。
三条裁决原话分别留在 11b／11c 的 ADR-001 落地记录；第 9 项的决策（为什么提取成脚本、
为什么不用 `workflow_call`、触发器的真实规则、刻意不动 `pre-release.yml` 的代价）
**都在 ADR-006 的落地记录里**，此处不重复。

**第 9 项结果**（细节见 ADR-006）：`release.yml` 的打包三步提取成
`.github/scripts/package-runtime.sh`（`stage`/`verify`/`smoke`，两个 workflow 各以三个 step
调用同一实现）；新增 `.github/workflows/candidate-artifact.yml`（`contents: read`、
**无任何输入能打开发布**、npm 路径）。两条 candidate case 真机 PASS（16 ＋ 15 断言）。
`tools/fetch-candidate.sh` 把 ADR-009 的**证据绑定**做成一步命令（核 run 成功、`head_sha`＝
被测提交、两个 artifact 成对、归档 digest、解包后逐文件 sha256），带假 gh 冒烟进 CI。
**7f 与 11d 都已落地**（细节见「证据边界 / 交接必知」里的结果段与 ADR-013）。

**第 10 项结果**：`AGENTS.md` → **71 行**（执行边界与证据协议，保留被代码按名引用的 §0–§6 编号），
`.test-install/README.md` → 操作手册（**186 行**；第 10 项交付时为 159 行，其后因补入种子存储的判据矩阵而增长）。两者都在 ADR-007 的行数预算内，遵守**单点描述**：
AGENTS 只留不变量 + 指针，不复述 case 清单（事实源是 registry）、命令表（`run.sh help`）与 CI 逐条
分工（workflows 与 CONTRIBUTING.md）。同批清掉的过期事实见本节上文那条 ✅。

**下一步 = 第 12 项：交付**

> ⚠️ **交付前必须看这一节：收尾阶段多了一个计划外改动**（2026-09-15）。第 10 项（文档）
> 完成后，写文档时发现并修掉了一个**威胁 ADR-004 的种子存储缺陷**（勿回退 #24：内容寻址 ＋
> 失败安全的发布 ＋ 占用名不许换 pin ＋ `seed_load` 四分返回码）。它是**测试政策/存储语义**
> 改动、**不是**纯文档，因此：
> - **必须与文档重生成分开审阅**——reviewer 别把它当 docs 一行带过；
> - `FAIL`→`UNMET` 的归类变化**不是放行**：`UNMET → 退出码 3 → INCOMPLETE`，只有 PASS 给
>   READY（矩阵见 README「种子管理」节）。它落实的是 ADR-003 早已写死的分类；旧代码把
>   "缺件"也返回 1（FAIL）反而是**与 ADR-003 矛盾**；
> - **人工那一轮要加种子路径的项**：pin A → pin B（不得覆盖 A 的字节）→ 同名重钉被拒
>   （`--force` 才放行）→ 发布中途杀掉再重跑（旧种子仍可用、无残留 staging）→ 旧 pin 记录
>   仍能被 `seed_load` 消费。**在人类看过它之前：不冻结产物对象、不写 `Tested-by`、不合并。**

- **12**：等代码/测试/文档全部完成且自动层核验后，**冻结最终提交与对象** → 人类同轮实测 →
  `finalize` → 用现有工具写 `Tested-by` → 合并。**改动了受验内容就不得移用旧确认。**
  人类那一轮**必须覆盖退役后的实际候选产物**（顾问对 11b 的硬条件）**与 `serve-floor` 清单**
  （11c 新增，至今没有人类实测）。
  **第 12 项跑 `verify` 时必须提供候选产物**：`verify` 的必需项按**整个 PR diff**（`--diff-base`
  默认 `main`，即 merge-base..工作树）算，**不是**按最后一次提交算。实测该 diff 有 **75 个文件**、
  命中 **16 / 18** 条 case（只有 `release-install/shipped-release` 与 `release-install/download-path`
  没被选中），所以两条 candidate 必然在其中；不给 `DSH_CANDIDATE_ARTIFACT` 就是**必需 UNMET**
  → 结论停在 INCOMPLETE（不是失败，是缺可测对象）。
  **两条路径都行**：优先**复用**冻结提交上已有的**成功 PR run**；否则**刻意 dispatch** 冻结的
  分支。**不管走哪条**，都要用 `tools/fetch-candidate.sh <run-id> --expect-sha-from <冻结提交>`
  取产物——它会把 run 成功、`head_sha`＝被测提交、两个 artifact 成对、归档 digest、解包后
  逐文件 sha256 全部核过。**`--ref` 只认分支/标签**，所以别按裸 SHA dispatch；记下期望 SHA
  再核对 run 的 `head_sha` **与** provenance 的 `commit`。**不需要**为了"让 provenance 变成
  dispatch"而多跑一次构建。
- **边界**：退役**不必**等人类实测；PR **#38 当前已不是 draft**（维护者 2026-09-15 15:55 点了
  ready for review，状态以 GitHub 为准，别照抄本文件）；**不启用 auto-merge、不发布、不改 pin、
  不 bump**。
- **治理（已执行，2026-09-13）**：`AGENTS.md` §6.3 的字面原先写着"人类复核并实测确认后，才允许
  提交/合并/发布"，与 ADR-007 的"允许工作提交、只限制合并与发布"直接矛盾。收束方式是**两件都做**：
  ① 先取人类对"本 PR 允许继续产生工作提交、但禁止合并与发布"的**明确许可**作为当前字面下的临时桥接；
  ② 在同一批治理改动里**永久对齐** `AGENTS.md` §6.3（写成"允许工作提交；未完成人类实测前不得宣称
  通过、不得合并/发布、不得写最终 `Tested-by`"）。**只取许可而永久留着矛盾字面是不可接受的**。
  该许可**不替代**最终人类验收，也不改变"禁止合并／禁止 auto-merge／禁止发布"的约束
  （draft 与否是 GitHub 上的当前状态，见上）。

**7c 落地记录（改动清单，供 review）**

| 改动 | 位置 | 为什么 |
|---|---|---|
| 产物内注册表文本解析 + wrapper 钩子派生 + overlay | 新库 `lib/patchset.sh`；`sandbox-lib.sh` 的 overlay 改为薄委托 | 映射表 L8/L9/L10；实现已迁到新库；CI 的 `patch-matrix.sh` 也已在 `24a63bf` 改锚（本地 3 build × 9 补丁全绿，CI `static` 真跑通过），旧文件随之退役 |
| `seed_load` / `seed_default_name` / `seed_asset_by_name` | `lib/seed.sh` | 种子消费的**唯一入口**，内部核对每个资产的 sha256（映射表 L2：哈希核对归 case，不能靠"存在性"） |
| `DSH_SEED_NAME` / `DSH_RELEASE_*` 进契约变量钉表 | `lib/sandbox.sh` | case 需要知道"这一轮用的是哪颗种子 / 哪个发布物实例" |
| `--release-tag` + 实例记录 + UNMET 闸门 | `run.sh`（`round.tsv` 也加了三键） | ADR-011 的 (case, 输入实例) 记账 |
| `inputs_selection_needs` 泛化 | `lib/inputs.sh` | 同一函数服务 npm 输入与发布物输入 |
| `artifact:branch-candidate` 接受归档**或**目录 | `lib/state.sh` | ADR-006 落地补充（`gh run download` 给目录） |
| 三处 `-S warning` 级别的 lint 修复与新护栏 | `tools/smoke-probes.sh`(21) / `smoke-patchset.sh`(20) / `smoke-runner.sh`(27→**42**) | 新机制必须自带护栏 |
| `requires` 修正 | `cases/registry.tsv` | 缺件语义错位：`host:glibc`（patchelf/loader）、`tool:readelf`、`tool:wget`、`tool:sha256sum`、`network:github`；`update/refresh-machinery` 补 `baseline-seed`+网络+arm64；`update/self-patch-set` 补 `baseline-seed` |
| install.sh 委派守卫补 `ask_yes_no()` | `.github/workflows/verify.yml` | 映射表 R1.3 的小缺口（旧 r1 查过、旧 CI 漏了） |

### 已实测通过（可复跑）

**七个冒烟脚本**（全部已进 CI 的 `static`；改 `lib/**` / `run.sh` / `serve.sh` / `cases/**` / `tools/**` 时它们是护栏）

| 脚本 | 通过项 | 覆盖一句话 |
|---|---|---|
| `tools/smoke-runner.sh` | 65 | 选择→前置→执行→补记→聚合→报告；五态归类；崩溃/空选择补 ERROR；人工项 fail-closed；**发布物输入实例解析失败 → UNMET 且不回退稳定版**；**候选产物前置接受归档或目录**；**种子：`set -u` 下的返回码、内容寻址、四分返回码、失败/中断不破坏已有种子、migrate 归位、staging 清扫、**信号 trap 必须清理并终止**（带反证）** |
| `tools/smoke-sandbox.sh` | 37 | 白名单与线上守卫；沙箱生命周期；收据；**内容身份**（等长改写/权限/链接目标）；**两套环境基底各自的边界** |
| `tools/smoke-inputs.sh` | 16 | 假 registry：dist-tag→精确版本+SRI+冻结；未选不联网；缺 integrity→UNMET；非法 selector 拒绝 |
| `tools/smoke-frozen.sh` | 67 | 冻结对象三层身份/载荷边界/两类漂移/轮次隔离/观察台账/同轮终结/旧开关硬拒绝；**serve 现写启动器不得改写载荷**（场景 4b，带反证） |
| `tools/smoke-probes.sh` | 21 | 行为探针的**触发派生**与失败语义：按 rel 派生 marker、条件条目=跳过、歧义=FAIL、声明了缺 marker=FAIL、探针进程失败=FAIL、全跳过=聚合成功 |
| `tools/smoke-patchset.sh` | 20 | 产物内注册表的**文本解析**（两/三/四段式混排、条件条目跳过、按补丁名反查）与 wrapper 钩子能力派生；反证文本解析与生产 getter 的 marker 逐条一致 |
| `tools/smoke-fetch-candidate.sh` | 25 | **候选产物的取证/绑定**逻辑（假 `gh`）：run 非 success／来源不是被测提交／缺 evidence／checksums 不符／artifact 过期／下载字节被篡改／用法错误／`--list-only` 不下载／双层 zip 布局 |

多数在 `state/smoke/` 里自造**独立 git 仓库 + 假清单 + 假 case**（隔离与冻结另加**假线上 HOME**）；
`smoke-probes.sh` 自造**假被测树 + 假注册表**；`smoke-fetch-candidate.sh` 用**假 `gh`**（真跑只走成功
路径，也没法让服务器返回坏 digest）。开发中它们抓到 20+ 个真实缺陷，"勿回退"一节是提炼。

**真机（arm64）实测 —— 自动层证据，不是人类验收**（**18/18 条 executor 跑过，全 PASS**）：

| case | 断言数 | 备注 |
|---|---|---|
| `dry-run/pristine-npm` | 23 | 约 2m15s；SRI 闭环 ＋ 三个行为探针 |
| `dry-run/pinned-rebase` | 15 | 幂等 rebase（`tree_changed=no`）＋ 探针 ＋ boot |
| `release-install/workspace-installer` | 22 | 含覆盖重装回归 |
| `release-install/shipped-release` | 47 | 实例身份 == `latest` == 种子 tag |
| `release-install/download-path` | 20 | **下载字节 sha == 种子 pin 的 sha** |
| `update/workspace-updater` | 22 | 真实升级链 alpha.1 → rc.1 |
| `update/shipped-updater` | 26 | 发布物内置更新器同链路 ＋ `--self` |
| `update/self-patch-set` | 35 | Part A–G（含负例未触碰 runtime） |
| `update/wrapper-entry` | 19 | 同一 argv 的逐字一致转发 |
| `update/refresh-machinery` | 19 | 刷新判定 + H1/H2 哨兵按设计中止 |
| `update/failure-recovery` | 25 | **仅** npm 解析阶段失败/中断（见「证据边界 / 交接必知」） |
| `update/post-install-patch-failure-recovery` | 37 | **7f 新增覆盖**；npm 成功后补丁失败：同克隆双控制 ＋ git shim 精确命中 1 次 ＋ 失败瞬间 8/8 marker 缺席 ＋ 同树恢复成功 |
| `setup-install/channel` | 15 | 渠道 × 工作区补丁集 |
| `setup-install/full-pipeline` | 18 | **152s**；真实 `00-setup.sh` 走完 01→04，runtime 自含 |
| `update/support-floor` | 47 | **11c 新增**；边界表 + 两个入口拒绝 + 调用记录器证明"拒绝时没有 `npm install`" + 安装树逐字未变 |
| `release-install/candidate-artifact` | 16 | **第 9 项新增覆盖**；真 CI 候选产物（run 35001588642 @`9680535`）装得上、glibc loader 正确、boot 通过 |
| `dry-run/candidate-artifact` | 15 | **第 9 项新增覆盖**；同一产物 × 工作区补丁集：overlay 幂等（`tree_changed=no`，产物本就带本分支补丁）＋ 三探针 ＋ boot |
| `release-install/legacy-tarball` | 22 | **11d 新增覆盖**；当前安装器 × 已发布旧 tarball（`pre-dsh-0.1.3-alpha.2-g82a5fd6-1.2.8`）：sha256 绑定 ＋ 真机解包(hardlinks=0) ＋ **no-overlay**（装出的 common.sh 逐字等于产物自带）＋ 接口兼容 ＋ CLI/wrapper/symlink ＋ **fs-ext 裸加载** |

**18/18 条 executor 都真机跑过。** 两条 candidate 的输入是**真 CI 产物**：workflow
`candidate-artifact` 由 PR 触发（run 35001588642，建在 `9680535` 上），
`gh run download` 下来后主 artifact 正好是三件套，CI 记的 sha256 与本地现算逐字一致
（`dsh-termux-runtime.tar.gz` `e93f6e35…`／`install.sh` `edc4c10c…` ≡ 工作区那份）。
**不许**把 UNMET 直接改写成 PASS —— 这几条是拿到真产物后**真跑**出来的。
跨运行同输入、不同仓库内容得到**完全相同**的 `pristine_tree`/`patched_tree`（`build_digest` 按预期不同）。

> **两次候选 run 的 tarball sha 不同，这是正常的，别当成缺陷**：实测
> run 35001588642（`9680535`）`dsh-termux-runtime.tar.gz` = `e93f6e35…`，run 35002582185
> （`263cc4b`） = `6d602dc3…`，而 **`install.sh`（`edc4c10c…`）与 `VERSION`（`64d23f85…`）
> 两次逐字相同**。
> **原因未确定，不许把某一种原因写成事实**：打包用的是一条朴素
> `tar -czf`（`.github/scripts/package-runtime.sh`），**没有** mtime／顺序归一化，所以
> 光凭"归档 sha 不同"**不足以**推出"依赖字节变了"——**元数据差异本身就够**造成不同归档。
> 与此同时 `build/build-runtime.sh` 走的是 `npm install <spec> --ignore-scripts`（无 lockfile
> 钉死），**可能**也会拉到不同的传递依赖。两者都只是**可能**：要断定是哪一种，得做
> "解包后逐文件比对依赖树"这种证据，本文件没有它。
> 因此：**记录"打包不保证可复现"这个结论，不记录未经证实的成因**；把每次的 tarball sha 当作
> **那一次被测字节的身份**（这正是 case-facts 里 `tarball_sha` 的用途）。
> 反过来，`install.sh`／`VERSION` 两次相同**也不等于**整棵 runtime 相同——它们只覆盖这两个文件。
> 要判断"是不是同一份代码"，看 provenance 里的 `commit`，不是任何一个 sha。

> **首跑抓到的真缺陷（已修，`d6d070d`）**：`dry-run/candidate-artifact` 第一次真跑时
> 8 ok / 5 failed，三个行为探针与 boot 全报
> `env: '…/node/bin/node': No such file or directory`（exit 127）。**不是候选产物的问题**：
> 发布物 tarball 里的 node 是未补丁的，设 glibc interpreter 是**安装器**的活，而这条 case
> 刻意只解包、不跑安装器（安装断言归 `release-install/*`），所以必须自己调
> `configure_glibc_node`（与 `dry-run/pinned-rebase` 同一处修正、同一原因）。这正是
> **勿回退 #21** 在新 case 里的复发——它只在真跑时现形，静态检查与 lint 都看不见。

**人类实测（2026-09-13；对象 id 以 `serve.sh --list` 为准，别抄文档里的）**：
`serve.sh --sandbox <名> --with-creds` → 人回复"测试均通过"，并点名三项：
① **浏览器自动弹出**；② **供应商凭据正常**（`~/.profile` 里的环境变量型 key 随**父环境**继承）；
③ **清单第 4 项（landlock tmpdir）正常**（`mktemp -d` 与 `$TMPDIR` 写入都成功）。
此前还确认过页面能打开并使用、文件读写在沙箱内。

**两条轨道，别混成一条**：
- **日常开发变更**：编辑 → 自动核验（`check`／CI）→ **工作提交**（可推主题分支）；
  人类实测**不是**这一步的前置（ADR-007）。
- **最终交付变更**：冻结最终提交与对象 → 人类同轮实测 → `finalize` → 写 `Tested-by` → 合并。
  冻结之后改动任何受跟踪文件都会让那份对象变成 `source=drift`（`git commit` 不改内容，不影响）。

**本机模拟 CI**：`.tmp-debug/ci-static-local.py` 逐步骤执行 `verify.yml` 的 `run:` 块，12 步全绿。

### 勿回退（按主题；每条都对应一个真踩过的失效）

**协议与聚合**
1. `case_begin` 不截断共享结果文件（截断归聚合端，case 只追加）。
2. 未登记的前置种类 → **ERROR(2)** 而非 UNMET(1)：看"是否完成了验证"。
3. `for x in $csv` 会做**路径展开**（registry 的 glob 从未真被检查）→ 一律 `registry_csv_tokens`。
4. stdout 只给报告、stderr 给过程（否则 `--json | jq` 当场炸）。
5. `check`/`full` 下点选即只跑点选的；空选择补 `framework/selection` ERROR，不许聚合出 PASS。
6. 轮次的 `human_required` 可能含"因缺 executor 而 ERROR 的 case"，`finalize` 会先在自动层拒绝。

**隔离与环境**
7. `local IFS=','` 会泄漏进被调库（透传名单被当成一个变量名，`env -i` 直接失败）。
8. `exec 9>&- 2>/dev/null` 会把 shell 的 stderr **永久**接到 /dev/null（只关 fd）。
9. `~/.dsh` 不能当违规证据（活着的会话一直在写，6 秒内签名就变）→ ADR-008。
10. **两种环境基底**（ADR-010）：case = 白名单，serve = 父环境 − 危险项 + 沙箱钉子。
    不可声称"隔离保证原封不动"；`ANDROID_{ART,I18N,TZDATA}_ROOT` 在 agent 环境里会让
    `am` 打不开 `/dev/binder`，但**默认不剥离**（只有 `--strip-android-root` 诊断开关）。

**收据与身份**
11. `DSH_RESULTS` / `DSH_BUILD_DIGEST` 必须在跑 case **之前**导出（白名单环境不继承命令行赋值）。
12. 树身份曾只记 (类型, 相对路径, 大小) → 等长改写/权限/链接目标都抓不住；现在是**内容清单**。
13. 合并摘要只能有**一个**算法（两处各拼一遍 → 每个对象都被判成漂移）。
14. `state_emit_json` 读未设置的 `DSH_RESULTS` 在 `set -u` 下**致命**（脚本当场退出，报告已打 READY）。

**serve 与人工证据**
15. 旧环境变量开关**硬拒绝**：静默忽略用户写下的开关，比报错糟糕得多。
16. `finalize` 读**那一轮的结果文件**判断选中，不读 registry 的默认值（全 no）。
17. `frozen_observe_append` 只接受**一个** note 字段（多传会被静默丢掉）→ 拼好再交。
18. 证据措辞：自动层与人工层是**互补证据**（受控 case 环境 + 人类这台设备的环境），
    不可跨环境抵消；诊断开关下的成功不能替代默认环境的人工项。
19. **`DSH_ASSUME_YES` 会跨脚本泄漏**：case 为了让 01/02/03 自动应答而 `export` 它，
    04 的最后一问"现在启动 dsh web 吗"就会**忽略 stdin** 直接 `exec dsh web`（首跑实测：
    它去抢 3080，撞上本机正在用的 GUI，04 以 EADDRINUSE 失败）。**自动层不启动 Web**：
    调 04 时必须显式 `DSH_ASSUME_YES=0` 再喂 stdin；`00-setup.sh -y` 同理一定会走到
    `exec web`，所以 `setup-install/full-pipeline` 用 `DSH_WEB_PORT=0`（不抢线上端口）+
    看到 `Starting dsh web at` 标记后**立刻停掉它**，并把"真的走到了这一步"作为断言。
    **不要**为了让 case 好写去改 04 的生产行为。
20. **函数头注释会吞掉下一行的 `local` 声明**：一次"顺手去空行"的编辑把
    `seed_verify() { # $1=name` 与 `local name="$1" f rc=0 …` 拼成了同一行 —— 声明成了注释
    的一部分，`bash -n` 与 shellcheck **都不报**（语法完全合法），只在 `set -u` 下以
    `rc: unbound variable` 现形（首跑 `seed set` 实测撞到）。教训：函数头的 `# ...` 注释
    后面**必须换行**再写 `local`；这类 bug 只能靠真跑或针对性的冒烟抓（`smoke-runner.sh`
    场景 8 就是为此加的）。
21. **发布物 tarball 里的 node 是未补丁的**：设 glibc interpreter 是安装器/更新器的活。任何
    "只解包、不跑安装器"的 case（如 `dry-run/pinned-rebase`、两条 candidate-artifact）在用它跑任何
    东西之前必须自己调 `configure_glibc_node`（幂等，与安装器同一实现），否则会以
    `env: '…/node': No such file or directory`（exit 127）假红——那是**动态装载器缺失**的症状，
    不是补丁或 overlay 的问题（首跑 `pinned-rebase` 整条红就是这么来的）。
22. **"overlay 前后树身份必须不同"是错断言**：工作区补丁集与发布物自带那套内容一致时
    （发布后没人改补丁＝常态），"先退旧集再打同内容新集"**幂等**，最终树与原后像逐字相同——
    那是好信号。判别器是 marker 齐全 + 行为探针 + boot；身份变化只记成事实
    （`tree_changed=yes/no`）。把它当断言会让常态变成红灯（首跑实测）。
23. **`cat > file` 会跟随 symlink**：`bin/dsh` 被安装器做成指向 `prefix/work/dsh` 的
    symlink（安装器的正常产物），而 serve 的启动器生成器用 `cat >` 写它——于是**写进了
    冻结载荷内部**；载荷校验（`frozen_object_ok`）在**这之前**就跑完，所以**不会被发现**。
    修法：写之前先摘链接。实测不摘时 `prefix/work/dsh` 的 sha256 立即改变，摘了则逐字不动。
    回归在 `tools/smoke-frozen.sh` 场景 4b，**带反证**（不摘就必须被改写，否则断言是空转）。
    教训推广：**"写在载荷之外"这种结构性主张，必须验证目标确实是普通文件**。

24. **种子资产曾是"扁平 + 同名"存储，`seed set` 会静默毁掉已有种子的字节**（2026-09-15 实测复现；
    **✅ 已修，同日**）。两个已复现的失效（当时用假字节在隔离沙箱复现，真实资产未受影响）：
    - **跨种子**：pin `stable`=tagA（rc=0）→ pin `other`=tagB → `stable` 变 `ASSET-CHANGED`／rc=1。
      两个 `.env` 都在，**外观上"并存"、字节上已被覆盖** —— ADR-004 在**记录层**成立、**字节层**被违反。
    - **单种子**（**不依赖多种子**）：`.part`→`mv` 是**逐资产**原子的、不是**每颗种子**原子的。
      re-pin 时资产 1 已 `mv`、资产 2 下载失败 → `.env` 仍是**旧 pin** 而旧字节已变 → 先前全绿的
      种子变红，且**两个 tag 都没有有效 pin**。
    **修法（顾问 `gpt-6-astra` 裁决 ＋ 用户拍板）**：① 资产改**内容寻址** `seed-assets/<sha256>/<名>`
    （内容决定路径 ⇒ 不同内容永不互相覆盖；路径**不是**信任依据，读前一律现算核对，不符即拒绝、绝不覆盖）；
    ② 发布**同址安全**：私有 staging → 逐件校验 → 只**新增**对象 → **最后**写 `.env`（一次失败的 pin
    绝不动已有种子），中断遗留的 staging 按 PID 清扫、并被 trap 收掉；③ **占用名下换 pin 默认拒绝**
    （ADR-004 要的是"旧 pin 记录仍可用"；想上新版本请换名，只有重发同一 tag 才 `--force`）；
    ④ `seed_load` 四分返回码（FAIL/ERROR/UNMET）＋ 唯一映射入口 `seed_load_require`（12 个 case 不再各写 switch）。
    回归在 `smoke-runner.sh` 场景 8（**带反证**：两份内容确实不同、活进程的 staging 不许被误删）。
    迁移：`run.sh seed migrate` 把与 pin 逐字相符的旧扁平资产归位（真实资产已归位，`stable` 仍 ASSET-OK）。
    教训推广：**"两个名字指向同一份字节"这种记录层承诺，必须在字节层也成立才算兑现。**

### 证据边界 / 交接必知

> 这里**不是待办清单**（待办只有进度表的第 10/12 项）——是**"报告能主张什么"的边界**，
> 换人后最容易读强的地方。

- ✅ **失败恢复两半都已覆盖**（实现规则见 **ADR-013**；契约收窄见下）。两条的证据边界
  必须分开读：
  - `update/failure-recovery`（25 断言）＝ 写入**之前**的失败/中断。证明 npm 解析/元数据
    获取阶段的确定性失败不改变用户数据与受测 runtime、失败后 boot 探针成功；中断结论**仅**
    涵盖证据中实际观察到 SIGKILL 的执行阶段，环境提前失败的执行不计为中断覆盖。
  - `update/post-install-patch-failure-recovery`（37 断言，7f）＝ **npm 成功改写安装树之后**
    补丁才失败。同配置双控制（关注入时同克隆第二棵树在同 shim/同目标下真实 npm＋补丁＋boot
    成功且 **0 次命中**；开注入时独立证明 npm exit 0、受管内容相对快照确实变化、**精确命中
    1 次**而另 3 次 apply 仍透传、updater 响亮非零、**失败瞬间 8/8 适用补丁的 marker 缺席**）。
    恢复**只撤注入**，不还原 npm 树、不重建种子，同树重跑成功。两次独立运行记下同一
    `tree_before`。

  **合并后的声明（照此措辞，不得加重）**：

  > 在固定种子及所测环境、禁用自动刷新机件分支（`DSH_SELF_DONE=1`）的条件下：
  > ① npm 解析/元数据获取阶段的确定性失败不改变用户数据及受测 runtime，且失败后既有 boot
  > 探针成功；中断结论仅涵盖证据中实际观察到 SIGKILL 的执行阶段。
  > ② npm **成功改写安装树之后**补丁应用失败时，用户数据（`$DSH_HOME` 整棵树）逐字未变；
  > 并且**只撤除注入、不还原 npm 树、不重建种子**，在同一棵失败树上重跑更新可成功、必需补丁
  > marker 齐全、boot 探针通过。该"恢复"只证明**按该步骤可恢复到通过既定 boot 探针**，
  > **不**证明失败瞬间即可用、原子更新、自动回滚、功能完整或任意中断无损。
  > **本结果仍不证明一般更新失败或任意阶段中断均无损、可运行或可恢复。**

  断言数（25／37）只支持上述范围；**registry.tsv 两条的 contract 字段与台账一致**。
  另一条独立 case 而非加 `network:npm` 的理由：`requires` 是**整条 case** 的前置，加了会让
  本来**离线可判**的场景在网络不可用时整体退化成 UNMET——等于丢掉已有离线证据。
- ✅ **`seeds/stable.env` 已建**（2026-09-13，维护者指定）：tag **`dsh-0.1.5-alpha.1-1.3.0`**
  （dsh `0.1.5-alpha.1`，项目 VERSION 1.3.0）——**与旧 `baseline.env` 的 pin 完全一致**，也就是说
  这次是"照旧 pin"而不是换目标；CI 的补丁矩阵本来就覆盖这个 build。两个资产的哈希已由
  `seed set` 现算写入（`dsh-termux-runtime.tar.gz` `793a9ebf…`／`install.sh` `edc4c10c…`），
  `seed show`/`seed list` 实测 ASSET-OK。**首次跑通了 `seed set` 的下载+pin 路径**，并当场抓到
  `seed_verify` 的 `local` 声明被注释吞掉的缺陷（见「勿回退」第 20 条）。
  按 ADR-004 这次种子变更仍要走 review（它是 pin 内容的批准）。
- ✅ **候选产物两条 case 已不再 UNMET**（第 9 项落地）：workflow
  `.github/workflows/candidate-artifact.yml` 上传三件套（ADR-006 落地补充要求的布局），
  两条 case 已用真 CI 产物真机跑通（16 ＋ 15 断言）。**取证方式**（下次重跑照此）：
  `gh run download <run-id> -n dsh-termux-candidate-<sha>-<run>-<attempt>` 得到目录，
  再 `DSH_CANDIDATE_ARTIFACT=<该目录> bash .test-install/run.sh check -c <case id>`。
  没有产物时它们仍记 UNMET（缺的是可测对象，不是结论）。
  **取产物：PR 触发是引导，之后 dispatch 也能用**。第一次必须由 PR 事件产生（workflow 注册
  的前提）；此后 `gh workflow run candidate-artifact.yml --ref <分支>` 对未合并分支同样有效
  （已实测，见上）。**别用"最新 artifact"挑产物**：按**精确 run id** 下载，并核对
  **该 run 是 success**、`head_sha` 等于被测提交、以及 artifact 的 sha256 digest ——
  **取消的 run 也会留下完整 artifact**（实测 35002807380 被 cancel 仍有 104MB 产物），
  所以"产物存在"≠"该 run 成功"。
- ✅ **11c 与 11d 都已落地**（详见 ADR-001 落地记录）：下限门禁已在两个入口生效，
  `update/support-floor` 真机首跑 **47 断言全 PASS**（含"拒绝时没有 `npm install`"与"安装树
  逐字未变"）。它带的人工清单 `serve-floor` **至今没有人类实测**——第 12 项的人类轮次必须
  覆盖它。**11d 也已落地**（`release-install/legacy-tarball`，真机 22 断言 PASS，见上文）；
  但**"旧版本仍可安装"这句话的主张边界**要照 11d 的记录读：它证明的是"当前安装器 ×
  这一个已发布旧 tarball"的兼容性与自足可运行性，**不是**所有旧版本、也不覆盖退役机件的
  因果。人工清单 `serve-legacy` 同样待人类实测。
- **`latest` ≠ 最新**：实测（2026-09-15）`latest=0.1.5-rc.1` / `next=0.1.5-rc.2` /
  `alpha=0.1.6-alpha.1`——**dist-tag 会漂**，任何断言都不许写死 tag 指向的版本。
- **条件补丁的覆盖率缺口是常态**（实测 9 条里 1 条不适用）；跳过不是已验证，要写进证据。
- **`--json` 需要 `python3`**（设备与 CI 都有；文本报告不依赖它）。
- **落盘布局**（都在 ignore 的 `state/` 下）：`<run-id>/`（results / report / build-receipt /
  guard / evidence / frozen-objects / input-npm-target）、`receipts/`（内容寻址 build 收据 +
  只追加的 `test.tsv` 与 `case-facts.tsv`）、`frozen/`（`frozen-<id>.tsv` 对象记录 +
  `observations.tsv` 台账 + `guard/` 快照 + `env/` **只记变量名**的审计清单）、
  `rounds/<run-id>/`（轮次）、`smoke/`（四个冒烟的假环境）。
  `run.sh clean` 删沙箱与 `<run-id>/`，**保留 `receipts/ rounds/ frozen/`**。
- **冻结对象占磁盘**（约等于一个 case 沙箱）；`verify` 会为带人工项的 case 留沙箱，这是刻意的
  ——人类实测时对象必须还在盘上。
- **源漂移检测覆盖整个工作树**（含文档），所以顺序是"改完 → 冻结 → 实测 → 终结 → 提交"。
- **`verify` 的必需项 = diff 命中 ∪ 显式点选**（`--diff-base` 默认 `main`）。

### 环境与协作约束（压缩后仍适用）

- **xiao 供应商不可用**；需要外部判断时用 **avemujica `gpt-6-astra`（`reasoning_effort=max`）**
  或 **`nvidia/moonshotai/kimi-k3`**，或直接问用户。
- **咨询粒度 = 一个决策一个会话**：① 针对具体决策开**新**会话；② 首条消息自己总结现状与决策需求；
  ③ 用 `send_message` 在同一会话里讨论到收敛；④ 收敛即停用。**不要用 fork 上下文，也不要用
  一次性（阻塞式 `run_in_background: false`）子代理会话**——那既不是持久会话，也会被取消。
- 沙箱铁律：**绝不触碰本地正在运行的 dsh runtime**（`~/.local/opt/dsh-termux-runtime/`、
  `~/.local/bin/dsh`、`~/.bashrc`、`~/.dsh`）；Termux 下禁访系统 `/tmp`，临时文件一律落工作区/沙箱内。
- 设备工具链：`python3` / `git` / `flock` / `curl`(glibc) / `wget` / GNU `find`·`stat` 有，
  **无 `jq`**，`node` 只在沙箱内。
- **子代理怎么用**：批量／执行类委托用便宜路由（`tokenrhythm/deepseek-flash`，**并发 ≤2**）；
  **不要**把批量工作丢给 `gpt-6-astra`（贵，且并发会互相拖）。只有"一个决策"才开顾问会话。
- **顾问会话的记录**：至今**六次**裁决（第 11 项拆两提交、11b 留本 PR 作独立提交、
  11c 现在做且 dist-tag 必须解析、第 9 项提取成共享脚本 ＋ 触发器的真实规则、
  shebang 保留现字节且不加分类护栏、11d 用 0.1.3 prerelease 作主体）**结论都已抄进
  ADR-001／006／012／013**，不要为同一个问题再开一次会话。
  **可用模型**：avemujica `gpt-6-astra`（`reasoning_effort=max`，慢但严谨）或
  `nvidia/moonshotai/kimi-k3`。
- 改测试体系与改仓库代码同等对待（同 PR、同 review）；策略类改动必须显式审阅。

---

## 修订后的实施顺序

**实施顺序就是上面「当前状态」进度表的第 1–12 项**（在这里再抄一份只会制造两份会漂移的
事实源）。两条贯穿始终、不随进度变化的原则：

1. **先定协议，不是先建目录**——结果/证据协议与隔离边界先于任何一条 case；
2. **旧文件退出的条件是"能力逐项有继承证据"**，不是"新体系看起来差不多了"。
   CI 的 case 级断言同样随 executor 落地逐步收紧，而不是一次性宣称已覆盖。
