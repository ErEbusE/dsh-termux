# STATUS.md — dsh-termux 测试体系重构：项目现状

> 本文件是**进度台账**，供上下文压缩/换人后接续。**决策的"为什么"不在这里**——
> 那是 `DECISIONS.md`（ADR-001..011、实查更正、附录 A 的迁移映射）。
> 规矩：改**进度**只改本文件；改**决定**只改 `DECISIONS.md`（两者都过 PR review）。
> 操作手册在 `README.md`；场景矩阵的**唯一事实源**是 `cases/registry.tsv`。

---

## 当前状态（RESUME HERE）

> 进度台账，供上下文压缩/换人后接续。改动进度时同步更新本节。
> 详细的"为什么"在 `DECISIONS.md` 的 ADR 里；本节只留**接续所必需的事实**。

### 现在在哪

- 分支 **`refactor/test-system`** 已推送、工作树干净、与 origin 同步；**draft PR #38**
  （→ `main`；`auto-merge` 关闭）。**提交数不看这里**——`git log --oneline origin/main..HEAD`
  才是事实源（写死数字每提交一次就过期一次）；下面是本轮相关的几个，细节见各条：
  `24a63bf` 补丁矩阵改锚 → `ab334a4` 退役旧测试体系 → `c4a95e7` `$TMPDIR` 文档修正
  → `60c9f38` 下线原生件机件（ADR-001）→ `d8af293` **支持下限门禁（11c）**
  → `70b1536`／`c9d43a6` 台账刷新与拆分（进度拆到本文件）。
  更早的八个是第 1–8 项那批（协议内核 → executor → 种子 → 台账/治理/缺口登记）。
- **CI**：**最近一次"完整"全绿是 `d8af293`**（`static` 54s；`patch-check` 的 `patches` 41s
  ＋ `build` 7m39s；`pre-release` 的 dry run 也过）。之后的提交都是纯文档（`static`／`patches`
  每次绿）。**那两个 job 是删掉原生件步骤之后跑的**——等于顺带证明支持版本走 npm 路径确实
  不需要编译原生件，且那三处 workflow 编辑没有破坏构建。**分支 tip 的 `build` 结论要现查
  `gh pr checks 38`，别引用这里**（它的路径过滤看的是整个 PR diff，不是这一次的改动）。
- **矩阵现状**：`cases/registry.tsv` **17 条** = 16 条有 executor（其中 **14 条真机跑过**；
  新增的 `update/support-floor` 首跑 **47 断言全 PASS**）
  + 1 条**只有登记、没有 executor** 的缺口 case（失败恢复的联网半边，见 7f）。
- **自动层入口** `run.sh`：`list | validate | check | verify | full | finalize | seed | clean`
  （旧 `r1..r6`/`all` 已不存在）。**人类实测入口** `serve.sh`：`--list | --round <轮次id> |
  --sandbox <名>`；开关一律 `--flag`，旧的环境变量写法（`WITH_CREDS=` 等）被**硬拒绝**。
- **当前位置**：第 1–7 项、11 的 ①②、11b、11c 都已落地；**下一步是第 9 项（候选产物 workflow）**，
  之后是失败恢复缺口 → 11d → 10 文档 → 12 交付（见下节）。
- **11 ①② 已落地**：先让 `.github/scripts/patch-matrix.sh` 改锚到 `lib/patchset.sh` +
  `seeds/*.env`（`24a63bf`；本地与 CI 都真跑过，3 build × 9 补丁全绿），再删 `routes/`、
  `sandbox-lib.sh`、`baseline.env`、`release-test/`（106MB，未跟踪；同一批字节在
  `seeds/seed-assets/` 里逐字相同），并同批清掉 `.gitignore` 的三条白名单与文档失效引用
  （附录 A 的映射是唯一删除依据）。
- **11b 原生件机件已下线**（`60c9f38`）：ADR-001 判定要删的五个函数、三个调用点
  （`02-install-dsh.sh`／`update-dsh.sh`／`build-runtime.sh`）、`.github/actions/build-natives/`、
  三个 workflow 的构建/上传引用与原生件专用测试逻辑（含 `release-install/shipped-release`
  那条"注册表非空"断言——它拿**工作区**注册表判 **shipped** 产物，既绑实现又不是被测对象的
  属性）全部删除；`PATCHES.md` 那一节改为"历史机制，现行构建已下线"。完整范围与措辞见
  ADR-001 的落地记录。
- **11c 支持下限门禁已落地**（`d8af293`）：`scripts/common.sh` 新增下限常量与**版本优先级**
  比较／目标解析助手（`dsh_version_below_floor`／`dsh_version_cmp`／`dsh_resolve_target_version`
  等），`scripts/update-dsh.sh` 与 `scripts/02-install-dsh.sh` 两个入口都在 **npm 改写安装树
  之前**把目标解析成**一个精确版本**、判定下限、低于下限即拒绝，并且**只把那个精确版本**交给
  npm（不再把原 tag 交回 npm 二次解析）；不可解析的目标一律拒绝，绝不当降级路径丢给 npm。
  拒绝文案给出：已解析版本、下限、原因（缺原生件）、以及**可照做的**替代路径，并附
  "npm 有版本 ≠ 有对应 release"的条件。新增 case `update/support-floor` 与人工清单
  `serve-floor`；帮助文本里的旧示例 `-v 0.1.0-rc.8` 换成了窗口内版本。
- ⚠️ **11d（未做；排在第 9 项之后、第 12 项之前）**：ADR-001 保留的"旧版本用**自己的
  tarball** 安装"这条路径**零回归覆盖**，而它现在是旧版本的唯一入口。最小做法：先选**一个
  确实发布过、资产完整**的 0.1.3.x／0.1.4.x release 做隔离回归（"当前安装器 × 对应旧
  tarball"，**不得**用 overlay 把被测旧产物偷偷换掉）。**不许**把"调用关系上不受影响"
  写成"已验证"。
- `AGENTS.md` §1/§4/§5 仍描述被替换的那套命令（有过渡提示）；完整重写是第 10 项。
  **§6.3 已与 ADR-007 对齐**（`644785c`）：允许工作提交与推送主题分支，但人类实测前不得宣称
  通过、不得合并/发布、不得写最终 `Tested-by`。

### 进度

| # | 事项 | 状态 |
|---|---|---|
| 1 | 决策记录 ADR-001..011 + 实查更正 C1–C5 | ✅ |
| 2 | 结果/证据协议内核 `lib/state.sh` | ✅ |
| 3 | case 清单 `cases/registry.tsv`（现 **17 条**，矩阵唯一事实源） | ✅ |
| 3b | 新入口 `run.sh` + 种子管理 | ✅ 冒烟 42 |
| 4 | 隔离与收据（白名单环境 / 全路径线上守卫 / build+test 收据） | ✅ 冒烟 37 |
| 5a | 具名输入解析与冻结（`default-target` + 发布物实例） | ✅ 冒烟 16 |
| 5b | 第一个真 case `dry-run/pristine-npm` | ✅ 23 断言（真机） |
| 6 | 冻结对象 serve（内容身份/载荷边界/漂移/轮次/观察台账/同轮终结 + 两套环境基底） | ✅ 冒烟 64 + 人类实测通过 |
| 7a | 旧断言 → 新 case 映射表（附录 A） | ✅ |
| 7b | 三个行为探针迁入 `lib/probes.sh` 并挂进 case | ✅ 冒烟 21 |
| 7c | 15 个 executor + 机制迁移（L8/L9/L10、ADR-011 记账） | ✅ |
| 7d | 种子 `seeds/stable.env`（`dsh-0.1.5-alpha.1-1.3.0`） | ✅ |
| 7e | 执行覆盖：13/15 真机跑过全 PASS | ✅ 剩 2 条被第 9 项阻塞 |
| 7g | `update/support-floor`（11c 新增）首跑 **47 断言全 PASS** | ✅ 真机 |
| 7f | 缺口 case `update/post-install-patch-failure-recovery` **已登记、无 executor** | ⏳ 实现排在 9 后 |
| 8 | 真实 `00-setup.sh` 入口 ✅ / wrapper 端到端 ✅ / 下载分支 ✅ / 失败恢复 ⚠️ 见 7f | ⚠️ |
| 9 | 分支候选产物 workflow（`publish=false` + `upload-artifact`，先做行为不变的提取提交） | ⏳ **下一步** |
| 10 | 文档重生成（AGENTS 60–120 行 / README 150–200 行） | ⏳ |
| 11 | 退役：patch-matrix 改锚 + `routes/`／`sandbox-lib.sh`／`baseline.env`／`release-test/` | ✅ ①② 已落地 |
| 11b | ADR-001 原生件机件下线（生产脚本 + CI action + case 断言 + 文档） | ✅ 独立 `refactor:` 提交 |
| 11c | 更新目标下限检查（两个入口 + 拒绝文案 + `update/support-floor` case） | ✅ 真机 47 断言 PASS |
| 11d | 旧 tarball 安装的隔离回归（ADR-001 保留路径，"当前安装器 × 旧 tarball"） | ⏳ 排在第 9 项之后、第 12 项之前 |
| 12 | 交付：冻结最终提交与对象 → 人类同轮实测/`finalize` → `Tested-by` → 合并 | ⏳ 依赖 9／7f／11d／10；人类那轮须覆盖**退役后的候选产物**与 `serve-floor` |

### 第 7 项已完成（7a/7b/7c）——细节在 `DECISIONS.md` 附录 A 与下面的 7c 落地记录表

- **7a** 附录 A：52 个断言组＋14 项公共能力＋3 个探针逐条写明"谁继承了它、还缺什么"。
- **7b** `lib/probes.sh`：三个探针 + 聚合入口，**触发 marker 按补丁目标 rel 从消费的注册表派生**
  （旧体系写死串的 H2 缺陷不再存在）；跳过 = 可见 n/a 且进 case-facts，声明了却缺 marker = **FAIL**。
- **7c** 15/15 executor + 机制迁移；矩阵 16 条（第 16 条＝失败恢复缺口的联网 case，故意无 executor）。

### 当前执行顺序（2026-09-15 更新）

**已完成**：11 ①②（`24a63bf`／`ab334a4`）→ 11b（`60c9f38`）→ 11c（`d8af293`）。
三条裁决原话分别留在：本节旧版（已执行完毕，故删除）、11b 的 ADR-001 落地记录、
11c 的 ADR-001 落地记录。

**下一步 = 第 9 项（分支候选产物 workflow）**

- **两个提交**：先来一个**保持原行为的构建入口提取**提交（`release.yml` 的构建入口：staging
  ＋ tarball 结构校验 ＋ installer smoke），再加**候选 workflow**（`contents: read`、不发布、
  只 `upload-artifact`，产物是**三件套** `dsh-termux-runtime.tar.gz` ＋ `install.sh` ＋ `VERSION`，
  与 pre-release staging 一致）。**不另写一套测试打包逻辑**（ADR-006）。
- 之后**派发它、下载产物、在真机上跑那两条现在必然 UNMET 的 candidate case**。
  **候选 workflow 只让它们可执行，不能把 UNMET 直接改成 PASS**；它也**不**解决失败恢复缺口。
- 顺手要修两处已过期的话：两条 candidate case 的头部还写着"pre-release 只上传 natives"
  （11b 已经把那段上传删了）。
- **风险（须如实说）**：`release.yml` 本身**无法在不发版的前提下端到端验证**（手动 dispatch
  会真的发布），只能靠候选 workflow 跑同一条共享代码路径来间接证明——这正是"先提取、
  再由候选 workflow 验证"这个顺序的理由。

**之后依次**：失败恢复缺口（`update/post-install-patch-failure-recovery` 的 executor，
见 7f）→ **11d**（旧 tarball 安装的隔离回归）→ **10 文档**（AGENTS 60–120 行 +
`.test-install/README.md` 150–200 行，**同一个 `docs:` 提交**，按文件拆只会留下互相矛盾的
中间版本）→ **12 交付**。

- **12**：等代码/测试/文档全部完成且自动层核验后，**冻结最终提交与对象** → 人类同轮实测 →
  `finalize` → 用现有工具写 `Tested-by` → 合并。**改动了受验内容就不得移用旧确认。**
  人类那一轮**必须覆盖退役后的实际候选产物**（顾问对 11b 的硬条件）**与 `serve-floor` 清单**
  （11c 新增，至今没有人类实测）。
- **边界**：退役**不必**等人类实测；PR **保持 draft** 到最终确认（draft 是流程提示，不是技术门禁）；
  **不启用 auto-merge、不发布、不改 pin、不 bump**。
- **治理（已执行，2026-09-13）**：`AGENTS.md` §6.3 的字面原先写着"人类复核并实测确认后，才允许
  提交/合并/发布"，与 ADR-007 的"允许工作提交、只限制合并与发布"直接矛盾。收束方式是**两件都做**：
  ① 先取人类对"本 PR 允许继续产生工作提交、但禁止合并与发布"的**明确许可**作为当前字面下的临时桥接；
  ② 在同一批治理改动里**永久对齐** `AGENTS.md` §6.3（写成"允许工作提交；未完成人类实测前不得宣称
  通过、不得合并/发布、不得写最终 `Tested-by`"）。**只取许可而永久留着矛盾字面是不可接受的**。
  该许可**不替代**最终人类验收，也不改变 draft、禁止 auto-merge、禁止发布的约束。

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

**六个冒烟脚本**（已进 CI 的 `static`；改 `lib/**` / `run.sh` / `serve.sh` / `cases/**` 时它们是护栏）

| 脚本 | 通过项 | 覆盖一句话 |
|---|---|---|
| `tools/smoke-runner.sh` | 42 | 选择→前置→执行→补记→聚合→报告；五态归类；崩溃/空选择补 ERROR；人工项 fail-closed；**发布物输入实例解析失败 → UNMET 且不回退稳定版**；**候选产物前置接受归档或目录**；**种子事实源在 `set -u` 下的返回码** |
| `tools/smoke-sandbox.sh` | 37 | 白名单与线上守卫；沙箱生命周期；收据；**内容身份**（等长改写/权限/链接目标）；**两套环境基底各自的边界** |
| `tools/smoke-inputs.sh` | 16 | 假 registry：dist-tag→精确版本+SRI+冻结；未选不联网；缺 integrity→UNMET；非法 selector 拒绝 |
| `tools/smoke-frozen.sh` | 64 | 冻结对象三层身份/载荷边界/两类漂移/轮次隔离/观察台账/同轮终结/旧开关硬拒绝 |
| `tools/smoke-probes.sh` | 21 | 行为探针的**触发派生**与失败语义：按 rel 派生 marker、条件条目=跳过、歧义=FAIL、声明了缺 marker=FAIL、探针进程失败=FAIL、全跳过=聚合成功 |
| `tools/smoke-patchset.sh` | 20 | 产物内注册表的**文本解析**（两/三/四段式混排、条件条目跳过、按补丁名反查）与 wrapper 钩子能力派生；反证文本解析与生产 getter 的 marker 逐条一致 |

前者四者都在 `state/smoke/` 里自造**独立 git 仓库 + 假清单 + 假 case**（隔离与冻结两个另加
**假线上 HOME**）；`smoke-probes.sh` 自造**假被测树 + 假注册表**。开发中它们抓到 19 个真实缺陷，
"勿回退"一节是提炼。

**真机（arm64）实测 —— 自动层证据，不是人类验收**（14/16 条 executor 跑过，全 PASS）：

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
| `update/failure-recovery` | 25 | **仅** npm 解析阶段失败/中断（见「尚未解决」） |
| `setup-install/channel` | 15 | 渠道 × 工作区补丁集 |
| `setup-install/full-pipeline` | 18 | **152s**；真实 `00-setup.sh` 走完 01→04，runtime 自含 |
| `update/support-floor` | 47 | **11c 新增**；边界表 + 两个入口拒绝 + 调用记录器证明"拒绝时没有 `npm install`" + 安装树逐字未变 |

**两条未跑**：`dry-run/candidate-artifact`、`release-install/candidate-artifact`（被第 9 项阻塞）。
跨运行同输入、不同仓库内容得到**完全相同**的 `pristine_tree`/`patched_tree`（`build_digest` 按预期不同）。

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
冻结之后改任何受跟踪文件都会让那份对象变成 `source=drift`（`git commit` 不改内容，不影响）。

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

### 尚未解决 / 交接必知

- **覆盖缺口三个，位置不同**：① 两条 `candidate-artifact` 因第 9 项未落地而必然 UNMET；
  ② `update/post-install-patch-failure-recovery` **有登记无 executor**（选中它 = ERROR，不是 UNMET）；
  ③ `update/failure-recovery` 的 contract 已按实际证据收窄（见下一条）。
  已跑 case 的清单与断言数在「已实测通过」表里，不在这里重复。
  已跑出的关键事实：真实升级链 **`0.1.5-alpha.1`（种子）→ `0.1.5-rc.1`（冻结目标）** 在工作区更新器与
  发布物内置更新器上**都走通了**；`download-path` 的真实下载字节 sha **==** 种子 pin 的 sha；
  `shipped-release` 的实例身份 == `latest` == 种子 tag；`self-patch-set` 七个 Part 全过；
  `refresh-machinery` 的 H1/H2 哨兵都按设计中止。**交付结论仍是「待人类实测」**：必须针对收尾后的
  精确提交与冻结对象重跑同轮实测。
- **失败恢复只证明了一半（已知边界，不许含糊）**：`update/failure-recovery` 证明的是
  **npm 解析/元数据获取阶段的确定性失败**、以及**证据中实际观察到 SIGKILL 的执行阶段**，
  在固定种子与所测环境下不改变用户数据与受测 runtime，且失败后既有 boot 探针成功。
  它**没有**证明「npm 成功改写安装树之后补丁失败」（实查更正 C5 的那一半）。
  **收窄后的声明（照此措辞，不得加重）**：

  > 在固定种子及所测环境、禁用自动刷新机件分支的条件下，已验证 npm 解析/元数据获取阶段的
  > 确定性失败不改变用户数据及受测 runtime，且失败后既有 boot 探针成功。中断结论仅涵盖证据中
  > 实际观察到 SIGKILL 的执行阶段；环境提前失败的执行不计为中断覆盖。
  > **尚未验证 npm 成功改写安装树后补丁失败时的用户数据保留与恢复路径。本结果不证明一般更新
  > 失败或任意阶段中断均无损、可运行或可恢复。**

  25 项断言的 PASS 只支持这个范围。**registry.tsv 里该 case 的 contract 字段已同步收窄**——
  台账与矩阵唯一事实源必须一致，不能只在台账里放低措辞。

- **缺口已登记为独立的联网 case**（顾问裁决 2026-09-13）：
  `update/post-install-patch-failure-recovery`，`requires=seed:stable,device:arm64,tool:git,network:npm`，
  `inputs=baseline-seed,npm-spec`（固定 npm 目标 + 匹配补丁集，避免跟 `latest` 漂移），
  `evidence=behavior,boot`（**联网不等于 `download` 证据**；真 npm 安装证据达到 `install` 定义才标它），
  `profiles=full`。
  **为什么新开一条而不是给现有 case 加 `network:npm`**：`requires` 是**整条 case** 的前置，
  加了它会让本来**离线可判**的两个场景在网络不可用时整体退化成 UNMET —— 等于把已有离线证据丢掉。
  两条并列后：离线 case 保留其有效结论，联网 case 在网络不可用时记 UNMET，**前者不能抵消后者的
  覆盖缺口**；未选中联网 case 也不等于已验证。**实现完成前，该 case 只有登记没有 executor ——
  选中它是 ERROR（框架补记），不是 UNMET**：这正是"未实现的覆盖缺口"该有的样子，
  不许假借"缺网络"包装成 UNMET。
  **注入设计（实现时必须核实，不许假定已有 API）**：首选**沙箱内窄作用域的补丁执行边界 failpoint** ——
  一个委派真实 git 的 shim，只拦"已确认 npm 之后的那一次必需补丁应用调用"，固定目标工作树与补丁身份，
  用专用退出码 + 独立命中记录；`--version`／退补丁／`--check`／普通探测**全部透传**；不伪造 npm 成功、
  不碰 `--self`。**"预先删坏 runtime 的 `patches/`"不天然确定**（可能被预检、marker/适用性跳过、
  机件被替换、npm 根本没成功或没造成内容变化），只能作为退路且必须证明不会被跳过。
  **双控制属于本 case 自己的同配置实验**（不得借用成功路径 case 的历史结果）：关闭注入时同克隆种子、
  同目标、同 shim 下真实 npm＋真实补丁＋boot 成功；开启注入时须独立证明 **npm exit 0**、
  **受管内容相对"注入已就位、更新尚未开始"的快照确实变化**（排除注入文件/日志/时间戳）、
  **精确命中补丁调用**、**updater 响亮非零**。未命中或提前误触发 = **ERROR**（注入/框架故障），
  既不是 PASS 也不是笼统 UNMET；缺网络/目标产物才 UNMET；已观察到的契约否定保留 **FAIL**。
  **恢复的定义**：只撤销注入、**不还原 npm 树、不重建种子**，在同一棵失败树上真实重跑更新并成功、
  必需补丁状态正确、boot 成功、持久用户内容仍在。**立即 boot 与恢复后 boot 分别记账**：后者只证明
  "按该步骤可恢复到通过既定 boot 探针"，**不**证明失败瞬间可用、原子更新、自动回滚、功能完整、
  或任意中断无损；只跑 `--help`／`--check`／重复失败**不算**恢复成功；继续保留 `DSH_SELF_DONE=1`
  的范围限定。实现与证据按同一顺序（11 → 9 → **本缺口** → 10 → 12）落地，同 PR/review，
  人类真机确认前保持「待人类实测」。
- ✅ **`seeds/stable.env` 已建**（2026-09-13，维护者指定）：tag **`dsh-0.1.5-alpha.1-1.3.0`**
  （dsh `0.1.5-alpha.1`，项目 VERSION 1.3.0）——**与旧 `baseline.env` 的 pin 完全一致**，也就是说
  这次是"照旧 pin"而不是换目标；CI 的补丁矩阵本来就覆盖这个 build。两个资产的哈希已由
  `seed set` 现算写入（`dsh-termux-runtime.tar.gz` `793a9ebf…`／`install.sh` `edc4c10c…`），
  `seed show`/`seed list` 实测 ASSET-OK。**首次跑通了 `seed set` 的下载+pin 路径**，并当场抓到
  `seed_verify` 的 `local` 声明被注释吞掉的缺陷（见「勿回退」第 20 条）。
  按 ADR-004 这次种子变更仍要走 review（它是 pin 内容的批准）。
- **候选产物两条 case 现在必然 UNMET**：第 9 项还没给 workflow 加上传 runtime 三件套的步骤（ADR-006
  落地补充里写了要求的布局）。
- **11c 已落地、11d 未做**（详见 ADR-001 落地记录）：下限门禁已在两个入口生效，
  `update/support-floor` 真机首跑 **47 断言全 PASS**（含"拒绝时没有 `npm install`"与"安装树
  逐字未变"）。它带的人工清单 `serve-floor` **至今没有人类实测**——第 12 项的人类轮次必须
  覆盖它。**仍未做**的是 ADR-001 保留的"旧版本用**自己的 tarball** 安装"这条路径的隔离回归
  （11d）：在它落地前，**不得**把"旧版本仍可安装"当作已验证结论写进交付证据。
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

- **xiao 供应商不可用**；需要外部判断时用 **avemujica 的 `gpt-6-astra`（effort max）** 或直接问用户。
- **咨询粒度 = 一个决策一个会话**：① 针对具体决策开**新**会话；② 首条消息自己总结现状与决策需求；
  ③ 用 `send_message` 在同一会话里讨论到收敛；④ 收敛即停用。**不要用 fork 上下文。**和不要使用一次性subagent会话。
- 沙箱铁律：**绝不触碰本地正在运行的 dsh runtime**（`~/.local/opt/dsh-termux-runtime/`、
  `~/.local/bin/dsh`、`~/.bashrc`、`~/.dsh`）；Termux 下禁访系统 `/tmp`，临时文件一律落工作区/沙箱内。
- 设备工具链：`python3` / `git` / `flock` / `curl`(glibc) / `wget` / GNU `find`·`stat` 有，
  **无 `jq`**，`node` 只在沙箱内。
- **子代理怎么用**：批量／执行类委托用便宜路由（`tokenrhythm/deepseek-flash`，**并发 ≤2**）；
  **不要**把批量工作丢给 `gpt-6-astra`（贵，且并发会互相拖）。只有"一个决策"才开顾问会话。
- **顾问会话的记录**：截至 2026-09-15 的三次裁决（第 11 项拆两提交、11b 留本 PR 作独立提交、
  11c 现在做且 dist-tag 必须解析）**结论都已抄进这两份文件**（本节 / `DECISIONS.md` 的
  ADR-001 落地记录 / 附录 A.9），不要为同一个问题再开一次会话。
- 改测试体系与改仓库代码同等对待（同 PR、同 review）；策略类改动必须显式审阅。

---

## 修订后的实施顺序

**实施顺序就是上面「当前状态」进度表的第 1–12 项**（在这里再抄一份只会制造两份会漂移的
事实源）。两条贯穿始终、不随进度变化的原则：

1. **先定协议，不是先建目录**——结果/证据协议与隔离边界先于任何一条 case；
2. **旧文件退出的条件是"能力逐项有继承证据"**，不是"新体系看起来差不多了"。
   CI 的 case 级断言同样随 executor 落地逐步收紧，而不是一次性宣称已覆盖。
