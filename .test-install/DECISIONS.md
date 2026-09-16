# DECISIONS.md — 测试体系重构的决策记录

> 本文件是**决策台账**：ADR-001..**014**、实查更正 C1–C5、附录 A（旧断言迁移映射）——
> 只记录"决定了什么、为什么、影响哪些文件"。
> **项目现状、进度与下一步在 `STATUS.md`**（上下文压缩后从那里接续）；
> 操作手册在 `README.md`；场景矩阵的**唯一事实源**是 `cases/registry.tsv`
> （本文件不复述矩阵）。改动本文件或任何门槛相关策略都必须过 PR review。
>
> 背景：本仓库的测试体系在 2026-09 整体重建，旧体系（六条 `rN` 路线）不保留、
> 不做兼容式叠加。本文记录重建前评审中拍板的事项与其依据。

---

## ADR-001 支持窗口：只支持 dsh >= 0.1.5-alpha.1

**决定**：npm 安装/升级路径只保证 `@deepseek-ai/dsh` >= **0.1.5-alpha.1**。
更早的版本一律通过其对应的 **release tarball** 安装（`install.sh -p` /
`DSH_RELEASE=<旧 tag>`），不再走 `npm install` 路径。

**依据**（实物核实，非推断）：

- 上游 `dsh-v0.1.5-alpha.1` release note：「修复 macOS 和 Linux 依赖 `fs-ext`
  需要本地编译的问题」；`dsh-v0.1.5-alpha.2` 又补：「修复 npm 安装需要依赖 `fs-ext`
  本地编译的问题」。
- 基线 tarball 与本机在跑版本的 `node_modules/@deepseek-ai/` 均**无 `fs-ext`**，
  取而代之是 `node-addon-system` + `node-addon-system-linux-arm64`
  （`bin/glibc/system.node`、`bin/musl/system.node`、静态 `bin/landlock-run`）。
- `node-pty` 自带 `prebuilds/linux-arm64/pty.node`；`sharp` 走 `@img/sharp-linux-arm64`。
- 结论：`npm install @deepseek-ai/dsh@<v> --ignore-scripts` 即得到完整可跑的
  arm64 运行时，**不需要消费侧编译，也不需要预编译原生件发布资产**。

**影响**：`scripts/common.sh` 的原生件机制（`native_prebuild_entries` 只声明
`fs-ext`、`build_native_addons`、`ensure_native_prebuilds`）、设备侧从 release 拉
`dsh-termux-natives.tar.gz` 的 overlay、CI 的 build-natives action，对已支持的版本
**全部空转且不报错**——按本 ADR 予以删除，而不是保留一套无人验证的兼容代码。

**边界用 SemVer 精确表达**：判定写 `>= 0.1.5-alpha.1`，不写含混的"0.1.5+"。

**落地记录（11b，顾问裁决 2026-09-13）**：删除范围 = `scripts/common.sh` 的五个函数
（`native_prebuild_entries`／`build_native_addons`／`verify_native_prebuilds`／
`package_native_prebuilds`／`ensure_native_prebuilds`，连同 `DSH_NATIVE_REPO`）、三个调用点
（`scripts/02-install-dsh.sh`、`scripts/update-dsh.sh`、`build/build-runtime.sh`）、
`.github/actions/build-natives/`，以及 `release.yml`／`pre-release.yml`／`patch-check.yml`
里的构建、上传与 `steps.natives` 引用；测试侧删掉 `release-install/shipped-release` 的原生件
断言与 `natives_checked`／`natives_skipped` 计数（**不**改写成"依赖树里没有需要编译的原生
依赖"这类广义反向断言——`.node`／`binding.gyp` 的存在不等于设备必须编译，没有 `fs-ext`
也不证明别的依赖将来不需要编译）。**不改补丁、不 bump `VERSION`、不重新 pin 种子、不碰
历史 release 资产。**

据此写下的边界（照此措辞）：

> 本次退役仅作用于当前构建与 npm 安装／升级机制；历史 release 资产保持不变，旧版本仍通过
> 对应 tarball 安装。旧 runtime 的机件刷新、仅 `--self` 与跨版本升级分别记账，不以历史安装
> 兼容性代替验证。

**它带回的两个缺口，以及后来的处置**：

1. **更新器没有目标版本下限检查 → 已补（11c，顾问裁决 2026-09-13）**：npm 路径原本仍接受
   窗口外目标，删掉 overlay 之后 `0.1.3.x`／`0.1.4.x` 会"装得上、起不来"（那两代需要
   `fs_ext.node`），而删除前它会去取预编译件——**静默降级**。现在两个入口
   （`scripts/update-dsh.sh`、`scripts/02-install-dsh.sh`）都：
   - 把目标解析成**一个精确版本**（精确版本本地比较、dist-tag 先查 dist-tags 表再用
     `npm view` 解析），**只把该精确版本交给 npm**，不把原 tag 交回 npm 二次解析；
   - 用**真正的 SemVer 优先级**比较（不是字符串排序、不是 `sort -V`、不是 npm 的范围
     匹配——范围匹配对 prerelease 的排除规则不是优先级比较），阈值 `0.1.5-alpha.1`；
   - 低于下限即**在 npm 改写安装树之前**拒绝，退出非零，且**不可解析的目标一律拒绝**
     （绝不以"查不到就交给 npm"当降级路径）；
   - 拒绝文案给出已解析版本、下限、原因，以及**可照做**的替代路径（`install.sh -p` /
     `DSH_RELEASE=<tag> bash install.sh`），并写明"npm 上有版本 ≠ 本项目有对应 release；
     没有对应发布物时该版本根本装不了"——**不**自动编造一个 tag。
   约束（照此执行，别扩散）：**不要**借机扩成更新恢复重构；`--self` 不因此平白多一次
   npm 查询（纯 `--self` 在到达目标解析前就退出）。证据：新 case `update/support-floor`
   （边界表 + 两个入口 + 调用记录器证明"拒绝时没有 `npm install`" + 安装树逐字未变 +
   拒绝文案内容 + `-h` 与哨兵块一致）与人工清单 `serve-floor`。
   **为什么门禁放在机件刷新之后也够**：刷新分支只替换本项目自己的脚本/补丁集，不碰 npm
   树；而"没有门禁的机件"与"有原生件的机件"来自同一个 release —— 一个既有更新器又缺
   原生件的组合只可能出现在本分支的中间状态，不会出现在任何发布物上。
2. **"旧版本走自己的 tarball"这条路径 → ✅ 已落地（11d，2026-09-15）**：原文写的
   "0.1.3.x／0.1.4.x release"**字面上做不到**——稳定渠道没有任何 0.1.3.x／0.1.4.x，
   0.1.4 在任何渠道都不存在，唯一的 0.1.3 是 prerelease
   `pre-dsh-0.1.3-alpha.2-g82a5fd6-1.2.8`（ADR-011 明确承认已发布的 prerelease 是有效实例）。
   实测选了它，理由不只是"唯一"：该 tarball 带**已编译**的 `fs_ext.node`，而
   `dsh-0.1.2-rc.1-1.2.8` 的 `fs-ext` 条目数为 **0**——0.1.2 不需要原生件，不能代表原生年代。
   **这条回归主张什么（照此措辞，不得加重）**：**当前工作区** `build/install.sh` 能安装
   该已发布旧 tarball（用产物**自带的** helper 集），装出的 runtime 通过声明的探针，且
   装出的 `common.sh` 与产物自带那份**逐字相同**（显式 no-overlay 对照）。
   它是"**当前安装器 ↔ 历史 helper 接口**"的兼容性 ＋ 该历史载荷的自足可运行性。
   **它不主张**：退役原生件机件的**因果**验证——被删代码**不在**这条执行路径上
   （`build/install.sh` 从未调用过它；调用它的是 npm 侧的 `02-install-dsh.sh`／
   `update-dsh.sh` 与 `build/build-runtime.sh`），删它在这条路径上**没有可观测差异**；
   也不覆盖 npm 路径、低于下限的 npm、`--self`、机件刷新、升级、其余历史版本。
   原生产物探针只证明**可加载**（`require` 成功且导出 `flock`），**不**证明 flock 语义。
   **不是空洞的**：安装器新增一个旧 helper 没有的函数/改签名、解包或 ELF 接线坏掉、
   载荷不对、旧原生件加载不了，都会让它红（反证另见 case-facts 与冒烟）。
   人工清单 `serve-legacy` 已登记，待人类实测。

---

## ADR-002 交付门槛模型：check / verify / full

**决定**：自动层有三个命令，语义严格区分：

| 命令 | 语义 | 是否授予交付资格 |
|---|---|---|
| `run.sh check` | 快集（离线或短网、不依赖大体积种子） | **否** |
| `run.sh verify` | **唯一交付裁决**：按改动范围机器规则算出必需 case + 核对人工证据 | 是 |
| `run.sh full` | 诊断性全量执行 | 否（它是执行范围，不是交付标准） |

**依据**：评审两轮独立指出——快集一旦叫 `gate`，就会事实上变成交付门槛，而
`full` 会退化为"有空再跑"。故弃用 `gate` 命名。

**配套**：CI 必须有一条**始终运行的 required 聚合检查**，读取同一份 case 清单与
结果，防止路径过滤让必需证据凭空消失或留下永久 pending。

---

## ADR-003 结果状态与退出码

**决定**：case 级状态为 `PASS / FAIL / UNMET / NOT_APPLICABLE / ERROR`，
未选中由聚合端记为 `NOT_SELECTED`。聚合优先级固定
**ERROR > FAIL > UNMET > PASS/N.A.**。

| 退出码 | 含义 |
|---|---|
| 0 | 所选必需项全部 PASS（其余为合法 N/A / NOT_SELECTED） |
| 1 | 存在 FAIL |
| 2 | 存在 ERROR（测试框架/配置自身故障） |
| 3 | 无 FAIL/ERROR，但存在必需 UNMET |

**分类看"是否完成了验证"，不看错误是否来自外部**：

- 预先声明的种子缺失、设备不可用、网络不可达 → **UNMET**（没有结论）
- 资产 hash 与 pin 不符、架构不符、被测脚本非零退出、断言不成立 → **FAIL**
- 测试框架自身损坏、无法解释的执行异常 → **ERROR**

**UNMET 不是较轻的 WARN**：它必须进报告正文的显式清单，**不得**塞进 WARN 汇总，
也**不得**阻断其他 case 执行——但它**必须阻断依赖该证据的交付结论**。
不存在"完整验证没做完、但完整验证通过"。

**交付结论独立于执行结果**：`READY / INCOMPLETE / REJECTED`
（缺必需人工证据 = INCOMPLETE，不是 PASS）。

---

## ADR-004 撤销 baseline 自动追随与直推豁免

**决定**：撤销现行的两条规则：

1. ~~发版后必须回来 `baseline set <新tag>`~~；
2. ~~机械 re-pin 是纯派生数据，agent 可直推 main 无需 PR~~。

改为：种子变更**走 review**；**旧种子保留**，不因新发版而淘汰。

**依据**：评审两轮独立指出——要求每次发版追 pin 会**不断消灭旧版本的升级覆盖
窗口**；而 pin 改变的是"测试覆盖哪些版本"的判断，不属于"纯派生数据"，不能因为
它由工具生成就免除 review。这与"基线固定 pin、不跟 latest"的原则一致。

**"保留"落在哪一层（2026-09-15 补记；顾问 `gpt-6-astra` 裁决 ＋ 用户拍板）**：
本条要求的是**旧 pin 记录仍然可用**（即可被 `seed_load` 消费的、还带版本关联的输入），
**不只是"字节还在磁盘上"**。这条澄清是被一个实测缺陷逼出来的——资产原先按
**固定资产名**扁平存放，于是"旧种子保留"在**记录层**成立、**字节层**被违反（详见
`STATUS.md` 勿回退 #24）。据此：
- 资产改为**内容寻址**存储（`seeds/seed-assets/<sha256>/<名>`）：内容决定路径，
  内容不同永不互相覆盖；路径**不是**信任依据，读前一律现算核对。
- **占用名下换 pin 默认被拒绝**（`seed set ... --force` 才允许）：想上新版本就
  **换一个种子名**。理由正是本条——一次经 review 的同名替换是**有意的**，但它**不保留**
  被替换掉的那个输入；而"孤儿字节"没有版本/资产关联，也不构成旧种子。
  这条与工具原先"可原地推进 `stable`"的文档**同步改**（否则等于静默废掉本 ADR）。
- 发布**同址安全**：失败或中断的 pin 绝不许破坏已有种子（先 staging 后入库、最后写 `.env`）。

---

## ADR-005 dry-run 按"被验证的契约"划分，来源降为参数

**决定**：case 的划分轴是**被验证的契约/状态转换**；
"干净 dsh 从哪来"（npm / 缓存 / 基线种子 / 分支候选产物）只是**输入参数**。

| case | 被验证的契约 |
|---|---|
| `dry-run/pristine-npm` | 干净 npm 树 + 工作区补丁与机件 → arm64 上可运行 |
| `dry-run/pinned-rebase` | 已发布 post-image + 工作区补丁集 rebase → 兼容且可运行 |
| `dry-run/candidate-artifact` | 分支候选产物 → 安装后可运行 |

**约束**：`pinned-rebase` **不是"干净来源"**；当请求的目标版本与种子实际版本不符时
必须**硬拒绝**，报告必须写明"不证明新版本兼容性"。安装类断言归
`release-install`，dry-run 只做组合与行为探针，同一结果不得重复计为两份覆盖。

**依据**：评审两轮独立否决"按来源划分"——同一契约会被拆成多套断言，且固定版本
的 overlay case 有被误用于测新版本漂移的风险。

---

## ADR-006 分支候选产物：立即做，复用生产构建入口

**决定**：新增/改造 workflow，用**正在构建的分支**产出仅供测试的完整产物
（runtime + installer + patchset + 校验和/来源信息），**不发版、不改 pin、
不写 release**，以 workflow artifact 形式供设备侧消费。

**实现约束**：复用 `release.yml` / `pre-release.yml` 的 arm64 构建入口，加
`publish=false` + `upload-artifact`，**不另写一套测试打包逻辑**；`contents: read`。

**与"纯净运行时缓存包"解耦**：后者的目的是省 npm 时间、属缓存性质，**后置**，
且必须先测量 `--ignore-scripts` 的真实耗时分布再决定，不能把现有 20min 当作
新条件下的必然结论。候选产物验证的是**打包/安装路径本身**，两者不是一件事。

**现状核实（写作时）**：`pre-release.yml` 的 dry-run 当时**只上传 natives**
（`:219-224`）；runtime 只在 publish 步骤作为 release 资产出现（`:376` 仅
`ARCHIVE` + `install.sh`，且刻意不含 patchset）。它走的是**源码路径**，
不能替代 npm 路径的候选验证。
**2026-09-15 更新**：那段 natives 上传已随 11b（ADR-001 下线原生件机件）删除，所以 dry-run
现在什么都不上传；本 ADR 的结论不变——候选产物仍须来自 **npm 路径**的构建入口。
两条 candidate case 头部"pre-release 只上传 natives"那句话要在第 9 项里一并改掉。
**（已做，见下方落地记录。）**

**落地补充（7c）**：

- 候选产物的**前置**接受**归档或目录**两种形态（`gh run download -n <name>` 给目录，
  `gh api .../zip` 给归档）；把它钉死成一种，另一种会在"前置"这一步被记成 UNMET ——
  那不是缺结论，是入口写死了。护栏在 `tools/smoke-runner.sh` 场景 7。
- case 侧**自己声明**要求的布局（`dry-run/candidate-artifact` 与
  `release-install/candidate-artifact` 头部都写明
  `<artifact>/{dsh-termux-runtime.tar.gz, install.sh, VERSION}`，与 pre-release
  staging 的产物三件套一致），不符就 `case_unmet` 并给出精确原因。**在上传步骤落地
  之前，这两条 case 必然 UNMET —— 那是正确行为**，不许为了让它们跑起来去改 workflow
  或放宽断言。

**落地记录（第 9 项，2026-09-15）**：

- **实现**：`release.yml` 的打包三步（stage ＋ 结构校验 ＋ installer smoke）提取为
  **`.github/scripts/package-runtime.sh`** 的 `stage`/`verify`/`smoke` 三个子命令，
  `release.yml` 与新的 `.github/workflows/candidate-artifact.yml` **各以三个 step 调用同一
  实现**（每 step 一个进程，保住 `set -e` 失败边界与 `$GITHUB_ENV` 交接）。本 ADR 的
  "不另写一套测试打包逻辑"因此落实为**同一份代码、两个调用者**。
- **为什么是脚本而不是 `workflow_call` 或 composite action**：仓库既有惯例是
  `.github/scripts/*.sh` 被 workflow 直接 `run`（`patch-matrix.sh`）；`workflow_call`
  会把 job/inputs/permissions/outputs 与发布编排一起搬走，等于在**无法端到端验证
  release** 的前提下增加待审面；composite action 只是多一层元数据，不解决新问题
  （11b 删掉 native action 不是对 composite 的一般性禁止，是它不再有用）。
- **产物**：主 artifact 恰为三件套（`dsh-termux-runtime.tar.gz`／`install.sh`／`VERSION`，
  即 case 声明的**输入布局**）；patchset 与 provenance/checksums 放**另一个 companion
  artifact**，以免污染主 artifact 的布局契约。**措辞纠正**：三件套**不等于**发布资产集合
  ——`release.yml` 发布的是 `{runtime, patches, install.sh}`（**无**独立 `VERSION` 资产），
  `pre-release.yml` 是 `{runtime, install.sh}`；成立的说法是"**runtime 的打包代码与发布共享**"
  （同一个 `package-runtime.sh` 的 stage），不是"逐字同一份资产清单"。
  provenance 记真实构建 commit、run id/attempt、requested spec、bundled dsh、Node 版本
  与 sha256 —— **必须有它**：case 只能比对 `VERSION`，而 `VERSION` 跨许多提交不变，
  单靠它无法说明"这是哪个提交的产物"（ADR-009 的资格绑定主体）。
- **触发器：PR 引导发现，之后 dispatch 也能用（原措辞已实测推翻）**：**第一次运行必须由
  PR 事件产生**——workflow 被注册/可发现的前提；`gh workflow run --ref <分支>` 单独**不能**
  引导一个从未跑过的 workflow。**但"合并前无法 dispatch"是错的**：跑过至少一次之后，
  CLI/API 就能对任意分支 dispatch。实测：对**未合并**的 PR 分支执行
  `gh workflow run candidate-artifact.yml --ref refactor/test-system` 被接受，产出 run
  35004183105（`event=workflow_dispatch`、`head_sha=7281fee`＝PR head、`conclusion=success`）。
  官方措辞也留了这个分寸：UI 的 Run workflow 按钮要求 workflow 在默认分支上，而"once a
  workflow has run at least once, you can dispatch it against any branch or tag via the
  GitHub API or GitHub CLI"。故同时挂 `pull_request`（带 path filter）与 `workflow_dispatch`，
  并**不用** `pull_request_target`。PR 的 checkout 钉在
  `github.event.pull_request.head.sha`：默认 pull_request 检出的是 GitHub 合成的 merge
  commit，不是"本分支的产物"。
  **没有**为此临时合并任何东西到 main：那需要另一次 review 与 main 变更，且违反
  "人类冻结对象确认前不得合并"的边界；分支级 `push:` 触发器虽然也能引导，但多一份
  临时配置与清理成本，且当前无优势。
  **`--ref` 的语义是分支/标签**，所以不要承诺"按裸 SHA dispatch"：记录期望的完整 SHA，
  跑完再核对该 run 的 `head_sha`**与**产物内 provenance 的 `commit` 都等于它。
- **刻意不动 `pre-release.yml`**：它是**源码路径**（`DSH_SOURCE_TREE`），且有
  `--hard-dereference` ＋拒绝 hard-link 条目这套与 npm 路径**真实不同**的处理。把两者
  合流要么改变 pre-release 行为，要么给提取引入若干未经运行验证的模式分支。
  **代价已记**：npm 打包路径**没有** hard-link 防御，Android 拒绝 `link(2)`，
  所以候选产物必须在真机上**真解包**（Ubuntu 的 installer smoke 不能代替）。
- **registry 补漏**：两条 candidate 的 `changes` 原先只盯 `.github/workflows/**`，
  **不含 `.github/scripts/**`** —— 打包代码一挪进新脚本，只改该脚本的提交就会绕过两条
  case。已把助手路径加进两条的 `changes`。
- **首跑抓到的真缺陷**：`dry-run/candidate-artifact` 第一次真跑 8 ok / 5 failed，
  三个行为探针与 boot 全报 exit 127（`env: '…/node': No such file or directory`）。
  发布物 tarball 里的 node 是**未补丁**的，设 glibc interpreter 是安装器的活，而这条
  case 刻意不跑安装器，所以必须自己调 `configure_glibc_node`（**勿回退 #21** 的复发，
  locale 与静态检查都看不见），修复后 15 断言 PASS。
- **仍未证明的（措辞已收紧，别夸大）**：release.yml 的 **input 解析／changed 与降级 gate／
  tag 守卫／notes／写 release 的编排**没有被端到端验证过。但**不许**说它们"原则上无法验证"——
  错了：这些**单件**逻辑（input 解析、tag 语法与冲突守卫、降级比较）都能在没有发布会话的
  条件下单独试验，只有"完整发布链路"才需要真发版。候选 run 证明的是**同一条共享打包路径
  被真跑过**。结论措辞只能是"静态等价审查 ＋ 提取出的路径成功执行"，**不是** "release
  已端到端验证"。
- **证据绑定是外部步骤，不是 case 的断言（实测确认，ADR-009 的既有欠账）**：两条
  candidate case **不校验产物的来源**——`dry-run/candidate-artifact` 只把产物 VERSION 与
  仓库 VERSION 比对并把它记进 case-facts；`release-install/candidate-artifact` **刻意**把
  "installer 与工作区不同字节"记成信息而不判失败。因此**一份来自别的提交的产物可以
  behavior PASS**。绑定（run 成功 ＋ `head_sha` 等于被测提交 ＋ artifact id/digest ＋
  解包后逐文件 sha256）**必须在第 12 项之前由外部步骤完成**，已实现为
  `tools/fetch-candidate.sh`（含拒绝路径的冒烟 `tools/smoke-fetch-candidate.sh`，进 CI）。
  **解析**下载来的 provenance，**绝不 source 它**（它是数据，不是代码）。
- **候选产物的三个具体陷阱（都已实测）**：① **取消的 run 也可能留下完整 artifact**
  （run 35002807380 被 `cancel-in-progress` 取消，仍留有 104MB 产物）→"产物存在"≠"run 成功"；
  ② 两个 artifact **不是原子上传**，必须取**同一个 run/attempt** 的一对，**绝不用"最新"挑**；
  ③ **归档的 digest ≠ 内层 tarball 的 checksum**，两者都要核。验收过的精确字节与证据
  应保留到 artifact 过期之后。
- **PR 触发的覆盖边界**：默认路径只覆盖 `opened`／`reopened`／`synchronize`；冲突、待批准、
  path filter 都可能让该 run **根本不产生**——所以"没看到 candidate run"**不是** PASS，
  必要时用 dispatch 补。候选 workflow **保持非必需检查**，必需要的仍只有 `static`。
- **concurrency 的分组用的是 `github.ref`**：PR（`refs/pull/N/merge`）与 dispatch
  （`refs/heads/<分支>`）**分组不同、互不取消**；但**同一 ref 的两次手动 dispatch
  会互相取消**——所以要按输入对比时别开 `cancel-in-progress` 的同类手工 run。
- **PR head 检出只证明"分支 head"**：它**不**验证与未来 main 的集成。rebase／冲突解决会
  改动被测内容，**受验内容变了就必须重测**。

---

## ADR-007 AGENTS.md 重定位与机器可读清单

**决定**：

- `AGENTS.md` 重定位为 **60–120 行**的"执行边界与证据协议"，不再是测试操作手册；
- `.test-install/README.md` 为 **150–200 行**操作手册；
- 引入**机器可读 case 清单**（`cases/registry.tsv`）作为
  `run.sh list --json`、README 矩阵、CI 汇总与 `verify` 必需项计算的**共同来源**；
  文档只解释"为什么"，不复述"有什么"。

**每次注入的不变量**（AGENTS.md 保留项）：线上 runtime 不可写；Termux 目录边界；
凭据纪律；源码树与安装产物是两个世界；测试结论不得伪造且证据须绑定被测对象；
测试代码同等 review；唯一交付检查入口；人工签认授权；**测试政策自身的改动须 review**。

**§0 改写方向**：不再讲"agent 的测试不算通过"。自动测试 PASS 是**有效结果**，
只对其报告的范围负责；设备上的自动运行可称 on-device automated，
**只有真人操作证据才是 human verified**。交付须满足本次风险契约要求的证据，
代理不得自行豁免；纯文档不强制人工项；纯测试改动不自动增加人工项，但**不得使
已有人工证据失效**。

**同时删除/修正**：§6 中直接操作线上 runtime 的示例（与沙箱边界自相矛盾）；
"先不许提交"与"证据必须绑定被测 commit"的矛盾（改为允许工作提交、限制合并与发布）。

---

## ADR-008 隔离：判定边界划在"预防"与"检测"之间

**决定**：隔离由三层组成，各自负责不同的事，**不能互相替代**：

| 层 | 手段 | 管什么 |
|---|---|---|
| 预防 | `env -i` + 显式白名单；`DSH_HOME`/`XDG_*`/`HOME`/`TMPDIR` 钉进沙箱；线上 wrapper 目录从 `PATH` 摘掉 | 让"忘了清某个变量"这类失效**在结构上不存在** |
| 检测 | 运行前后对**线上安装**做全路径签名比对 | 万一越界了，必须**响亮地**把这次运行的结论作废 |
| 观察 | build receipt 记录平台/输入摘要 | 结论绑定到对象（见"收据"一节） |

**判定边界（关键）**：能作为"违规证据"的路径，必须满足**除测试之外没有别的写者**。据此：

- **在守卫里**（变了 = 违规）：`~/.local/opt/dsh-termux-runtime` 整棵树、
  `~/.local/bin/dsh`、`~/.bashrc`、`~/.bash_profile`、`~/.profile`；
- **刻意不在守卫里**：`~/.dsh`。它是**活着的会话状态目录**——只要用户在用 dsh
  （比如正开着 web 会话），里面就一直在被写，实测 6 秒间隔两次签名已不同。
  把一个"一直在变的东西"当红线信号，结果是每次都红；**一个总是红的守卫等于没有守卫**，
  而且会让真正的越界淹没在噪声里。

**范围（2026-09 补充）**：上面这套"白名单 + 钉子 + 守卫"是 **case** 的政策。
人类实测入口 `serve.sh` 用的是**父环境基底**（父环境 − 危险项 + 同一套钉子 + 同一套守卫），
理由与它移动了的边界见 **ADR-010「环境基底」**——白名单挡不住"浏览器交接要用的真实环境特征"
（真机实测：白名单下浏览器 4 次全不弹），而人类实测要的就是真实用户的环境。

**残留风险（已知并接受）**：case 若硬编码 `$DSH_LIVE_HOME/.dsh` 去写线上状态，
当前不会被自动抓住。补偿手段是上面那三道预防 + **code review**：case 里出现
`$DSH_LIVE_HOME` 只允许出现在断言里（`lib/sandbox.sh` 的注释把这条写给了 review）。

**依据**：本轮实测。第一版守卫把 `~/.dsh` 算了进去，冒烟立刻假红；顺着查才发现
是本机正在使用的 dsh 会话在写它。同时**不能因此干脆不设守卫**——旧体系的问题恰恰
是只守 node 二进制（C4），证明不了安装树与 wrapper 没被动过。

---

## ADR-009 版本政策三层 + 裁决资格范围

**决定**：把"测哪个 dsh 版本"拆成三个**互不替代**的问题，各自有各自的政策：

| 层 | 是谁 | 政策 |
|---|---|---|
| 升级起点 | 发布物种子（`seeds/<name>.env` 钉住的 tag） | **钉死不跟 latest**，保住旧版本的升级覆盖窗口 |
| 当前安装目标 | 用户走默认安装路径会装到的版本（`default-target` 具名输入） | 每轮**解析一次并原子冻结**，冻结结果进 build receipt；case 拿到的是精确完整 spec，不是 dist-tag |
| 兼容性代表输入 | 支持边界版本、条件补丁正例 | 按契约风险作为**额外具名输入**，不默认每次双跑 |

**不许用一个 npm spec 同时承担这三件事。** 依据：只测最低支持版本，可能让
"只能处理旧上游"的补丁集拿到资格，而用户默认安装路径已经坏了；反过来，
`latest` 也代表不了整个支持窗口。

**配套硬规则**

- 解析**只**在选中集合里确实有 case 声明需要该输入时发生；`help`/`list`/`validate`
  与纯离线 profile 不得因此联网。
- 解析失败 → 依赖该输入的 case 记 **UNMET**，其他独立 case 照跑；
  **绝不回退到上一轮的旧目标**（那会得出"针对当前默认安装"的资格，而实际测的是别的版本）。
- 只支持**固定包名 + dist-tag 或精确版本**；范围/alias/URL 明确报错，不静默降级。
  缺 `dist.integrity` 不接受退化为"只比版本"。
- 顶层包精确 **≠** 依赖树固定：传递依赖、平台可选依赖、npm 版本、既有 lockfile
  都会改变最终产物。实际装出来的对象由 case 在安装后记录（lockfile 摘要、
  实测 node/npm 版本、补丁前树与最终对象的内容摘要），**不回写**已寻址的输入 receipt。

**SRI 的证明链（刻意不做下载代理）**

1. 真实 `npm install` 校验下载字节符合它取到的 metadata integrity；
2. 测试再校验 npm **实际采用**的那条 integrity（从装出来的 `package-lock.json` 读）
   等于冻结的 expected SRI；
3. 另核对已安装 `package.json` 的 `name`/`version`。

链的结论是"**错误字节不能获得通过结论**"，**不是**"错误字节从未落盘"。要做到后者
才需要受控下载通道，本 case 不需要。明确记为**不够**的三种做法：只核对装完后的
包名/版本；另下一份 tarball 验哈希却不关联 npm 的实际消费；缺 integrity 时退化成
版本检查。**不得声称"仅读 lockfile 就独立验证了下载字节"**——lock 是 npm 的执行
证据，不是独立的字节证明。

**裁决资格范围**（回应"上游发版会不会让我们的裁决变红"）

- 上游变化使**新一轮面向当前安装目标**的 `verify` 变红，是**正确暴露兼容性失效**，
  不是把交付权交给第三方——选择了浮动目标就选择了这项外部约束。
- 资格必须**绑定主体**：候选源码/发布资产摘要、平台、安装或升级路径、起始种子、
  目标输入与实际补丁集。**"工作区补丁适用于 npm"不得外推为"shipped 更新器已验证"。**
- 已完成的 PASS 只属于它 receipt 绑定那组输入；上游发版**不追溯改写**历史 PASS，
  旧 PASS 也**不能**自动证明"现在的 latest"。冻结输入重放是**重放**，
  不是重新认证当前默认目标。
- `N/A` **不偿还**正例债务；缺必需正例时相应资格一律不授予。
- 故障分类不得兜底洗白：网络不可达 = UNMET；完整性不符 / 装错版本 / 契约断言失败
  = FAIL；非法配置、解析器错误 = ERROR。
- **必要证据写不进去 = 不授资格**（收据写入失败不得只留一句 WARNING 就算过）。

**落地分档（照此执行）**

- **现在（✅ 已完成，见 `STATUS.md` 进度表 5a/5b/6）**：`default-target` 单角色冻结 + 已知 npm 消费者 TSV 补齐 + 精确参数真实
  传递 + 上述 SRI 闭环 + 干净树检查与实际对象摘要 + 逐补丁适用/应用/marker +
  arm64 boot；证据从第一天就绑定 `case × 输入 × 实际对象 × 证据等级`。
- **等会儿（仍欠，归属见括号）**：`support-floor` 与条件补丁正负例矩阵及其自动选入（第 7c）；
  updater 的 `TARGET` 传递与 re-exec、GitHub 机件冻结（第 8）；其余消费者的输入审计（第 7a）；
  "未指定目标确实选 latest"的离线单测（第 7b 一带）；`--diff-base` 可信来源政策、
  跨运行与人工证据复用（第 12 前）。
  **这些在各自契约被授予资格之前必须完成**，不许把"以后再自动化"变成永久人工记忆。
- **永不做**：SRI 只记不验；把顶层精确版本当完整 runtime 身份；为了确定性偷偷把
  真实安装改成 `npm ci` 或换 tarball 源却仍称"默认 registry 安装"；用 N/A 抵正例；
  解析失败回退旧 latest；用单 case 或 x64 结果冒充完整 arm64 交付。

---

## ADR-010 人类实测对象：冻结、身份三层、同轮终结

**决定**：人类实测的对象必须是**某条 case 装出来并被断言过的那棵树**，serve 只启动它，
不生成、不修补、不覆盖任何内容。为此引入三个东西：

| 概念 | 是什么 | 落在哪 |
|---|---|---|
| 冻结对象（manifest） | 把"哪组输入 / 哪些字节 / 哪一次执行 / 要照哪份清单"绑成一卷 | `state/frozen/frozen-<id>.tsv`（内容寻址、无时间戳）+ 沙箱内 `frozen.tsv` 定位副本 |
| 轮次（round） | 一次 `verify` 开的判定回合：不重跑、不重新解析 `default-target` | `state/rounds/<run-id>/`（results/round/objects/冻结输入） |
| 观察台账 | 每次 serve 会话的起止校验与人工清单覆盖 | `state/frozen/observations.tsv`（只追加） |

**为什么必须这样**（实查更正 C3）：旧 `serve.sh` 先跑 `r2 --tag` **认证发布物**，随后
**无条件**把工作区补丁 overlay 到它的 work 树上——人类实测的对象已经不是被认证的那一个，
而交付说明仍按被认证的写。修法不是"少 overlay 一点"，而是让"人类实测的对象"有身份。

**身份三层，互不替代**（评审结论；缺一层就有一类失效挡不住）：

- `build_digest` —— 这次资格针对**哪组输入**（含解析并冻结的 npm 目标）；
- **载荷内容摘要** —— 人实际启动的是**哪些字节**。同一个 build 可能产出不同对象；
- `run_id` / `case_id` —— 哪一次执行、走**哪条过程**得到它。同一棵最终树证明不了
  安装路径与升级路径都验证过。
- 另记人工清单**正文文件的摘要**：签认要能引用"人到底照着哪份清单做的"，而清单正文
  是数据文件（`cases/checklists/<id>.txt`）不是 serve.sh 里的字面量。

**载荷边界**：载荷 = `prefix/work`（装出来的 dsh 与依赖） + `prefix/node/bin`（解释器），
**排除** `.cache`。可写区（`home/`、`tmp/`、`ws/`）与机件（`bin/` 下的启动器）**不在**
身份里：人类实测**本身**就在写可写区，把它算进身份就是"每次必红的检测"（同 ADR-008 里
`~/.dsh` 那条教训）。机件由 serve 现生成、单独记摘要——它是被测对象的**外壳**，不是候选内容。

**漂移两分，处置不同**：

- **载荷漂移**（对象被改过）→ **硬拒绝**，`--allow-drift` 也绕不过去；
- **源漂移**（工作区内容变了）→ 需显式 `--allow-drift`，且这次观察仍归属于**冻结记录里的
  旧主体**，不提供当前工作区的资格。

serve 是**防误测**的闸门，不是最终资格闸门；真正的闸门是 `verify` 的终结检查。

**签认必须绑定对象，且只在本轮内有效**：

- 旧写法 `--signed <清单id>` **已删除**：一个清单名指不回任何对象，于是"人测的那棵树"
  与"这一轮判的那棵树"之间没有任何连接。现在只有
  `run.sh finalize <轮次id> --observed <对象id,…>`，对象 id 是 manifest 的摘要。
- 终结要求：该对象 (a) 在 `--observed` 里被明确点名、(b) 有**完整**观察（start 与 end
  都 ok——只有"开始时是对的"证明不了实测过程中没被换掉）、(c) 现在仍与冻结记录一致、
  (d) 属于同一轮次。**逐对象**：同一人工清单 id 下有多少条 case 就要实测多少个对象，
  在一棵树上点过的通过不能自动覆盖另一棵。
- **同轮终结不是新一轮执行**：不重跑 case、不重新解析 `default-target`。独立发起的
  新 `verify` 是**新轮次**，不能消费旧轮次的人工签认，**即便 build digest 相同**。
- 没走完这条路的 `verify`，结论一律停在 **INCOMPLETE**——这是结构性的（`run.sh` 给
  `DSH_HUMAN_COVERED` 传空值），不靠人记得别传参数。

**环境基底：case 与 serve 刻意不同**（本轮外部评审裁决；真机实测驱动）

| | case | serve（人类实测入口） |
|---|---|---|
| 基底 | `env -i` + **白名单** | **父环境 − 危险项 + 沙箱钉子** |
| 政策 id | `case-whitelist/1` | `serve-parent/1`（进观察台账） |
| 为什么 | 无人值守、必须可复现；"未知变量进不来"是结构性保证 | 人类实测本来就是"按真实用户的环境跑一遍"；白名单下实测浏览器不弹、`~/.profile` 的 provider key 进不来 |

- **不能声称隔离保证原封不动**：钉子 + 路径字符串过滤 + 前后签名挡不住"读外部凭据、
  经 `SSH_AUTH_SOCK` 使用身份、短暂写后还原、经 `BASH_ENV` 注入启动代码"。这是本决策
  移动了的边界，写在这里，不是重新审守卫。
- **联合结论必须写成互补证据**："该载荷在受控 case 环境下满足自动断言" **且** "在人类这台
  设备与启动环境下满足人工清单"——**不是**"自动断言在人类环境里又成立了一遍"，也不是
  "产品在所有父环境下都成立"。
- **不许跨环境抵消**：同一验收要求在某个环境下已出现的 FAIL，不能被另一个环境的 PASS
  自动冲掉；探针只证明了**当前白名单不够用**，没有证明"白名单原则上无法代表真实环境"。
- **不默认替产品修问题**：`ANDROID_{ART,I18N,TZDATA}_ROOT` 在 agent 环境里实测让 `am`
  打不开 `/dev/binder`（delta-debugging 到最小失败集合，三个缺一不可），而人类自己的环境
  带着它们照样能弹——**默认保留**，剥离只作为 `--strip-android-root` 诊断开关；
  若"清理三项"最终要被当作交付支持策略，必须落到真实产品 opener/wrapper 上再重新冻结验收。
- **凭据可见性不能一起删**：`--with-creds` 只复制凭据**文件**，**不是总闸**（父环境里的
  环境变量型凭据默认就会继承）。台账记 `env_policy` 与**丢弃的变量名**，`frozen/env/*.names.txt`
  留一份**继承下来的变量名清单**（只有名字；不记值，也不记值的摘要）。
  `GH_TOKEN`/`GITHUB_TOKEN` 的丢弃只是减少一条常见泄漏路径，**不构成**"沙箱里没有推仓库
  能力"的保证（别的令牌名、认证代理、`~/.git-credentials`、ssh agent socket 都可能等效）。

- **浏览器交接默认不插桩**：`$BROWSER` 是启动选择的一部分，把它换成我们自己的记录脚本
  可能遮住产品原本错误的接线；而启动器不在载荷身份里，manifest 校验证明不了这件事。
  所以默认走生成器写出的**原生接线**，且 serve **不对"弹没弹"下结论**（以人看到页面为准）；
  定位问题时才用 `--probe-handoff`，结论**分层**——没被调用／被调用但没返回／返回 0／返回 N，
  其中"返回 0"只证明**那个进程返回**，不证明浏览器打开了。URL 与输出里的 `token=` 一律打码，
  全量 URL 只在终端给一次、不落台账。
- **诊断开关下的成功不能替代默认环境的人工项**（`--probe-handoff` / `--strip-android-root`）；
  两者都进观察台账（`probe_handoff=` / `strip_android_root=`），适用范围写在证据里。

**已知残留风险（接受）**：观察台账记 `tty=yes/no`，但"人是不是真的测了"仍是**流程信任**
——agent 有 shell 就能启动 serve。机器能保证的是"证据指向的对象是对的"，那是可以自动
检查的；"人说没说真话"不能。同理，`~/.dsh` 那种"一直在变的东西"不做红线（ADR-008）。

**依据**：本轮评审（外部顾问，独立两轮）与实测。评审同时驳回了两处：

1. 原来的对象身份函数 `receipt_tree_id` 只记 `(类型, 相对路径, 大小)`——**等长改写**
   （6 字节换 6 字节）、改**执行位**、改**符号链接目标**都不会改变摘要，而"冻结对象的漂移
   判定"正建立在它上面。已改为规范化**内容清单**（内容摘要 + 相对路径 + 类型 + 权限 +
   链接目标；目录大小与 mtime 一律不计），并在冒烟里逐条钉死。
2. "只打印身份让人回复"不足以构成资格绑定；故本项直接做到同轮终结，而不是先留一个
   `--signed <清单id>` 的裸入口。

---

## ADR-011 发布物认证：一条契约、多个输入实例（pre 渠道不拆 case）

**决定**（第 7a 步迁移期间，就旧 r2 `--tag <pre-…>` 的归属裁决）：

1. **保留"认证已发布的 prerelease 发布物"这个能力**，但**不为它新增 case**：稳定 release
   与 pre release 的**前置状态、安装转换、断言完全相同**，按 ADR-005 的划分轴（被验证的
   契约）它们是同一条 case `release-install/shipped-release`，区别只是**输入实例**。
   （注：ADR-005 正文只讨论 dry-run，说"它直接规定了 release-install"是过度引用；
   本条的论证是"契约相同"，与 ADR-005 的划分轴**一致**，不是由它推出。）
2. **输入建模**：`release-assets` 是**逻辑输入槽**；具名配置给出 ① 来源仓库＋**精确 tag**
   （或默认稳定选择器，轮初解析并冻结）② 可选的本地预下载资产目录。目录只是载体：必须
   携带**来源清单**并核对 repo／tag／release id／**实际 prerelease 标志**／资产标识与每个
   资产的 SHA-256。**缺少可核验的发布来源时，只能声称"认证了本地资产"，不得声称"认证了
   已发布的 prerelease"。**
   - 不用 `seeds/<name>` 去选当前发布物，也不隐式复用 npm 的 `default-target`（两条不同的链）；
     shipped 的安装目标由**发布物自身**确定。
   - 默认值＝**稳定发布选择器**（`releases/latest`），轮初解析一次并冻结；显式 pre tag
     **不写回默认**，不因目录名或缓存自动切换，**不回退稳定版**。
3. **证据**：必须含 case id ＋**输入实例/轮次**、原始选择器与冻结来源、资产与 `install.sh`
   摘要、平台、安装路径与干净初态（种子 N/A 或记名与摘要）、实际安装版本/可取得的构建标识、
   实际补丁集与适用/跳过情况、各断言及人工状态。**报告不得只写 case PASS ——资格键至少是
   （case ＋ 冻结主体身份）**，否则一次 pre 认证会被读成稳定渠道认证（ADR-009"资格绑定主体"）。
4. **调度**：`verify` 的 diff 默认产生**稳定实例**；显式 pre 产生**该 pre 实例**；两者同时被
   要求时**都保留**，pre 的 PASS 不冲掉稳定必需项；未点选 pre 时**不常态双跑**。旧稳定资产的
   PASS 不能自动认证当前候选源码。
5. **不因"pre"这个名字拆场景**。只有将来"prerelease 的渠道发现／显式 tag 解析／渠道隔离"
   成为独立契约时，才新增对应 case。**`pre-release.yml` 的发布政策不变。**

**已落地（7c）**：机制取"**一次运行 = 一个输入实例**"，因为结果/轮次本来就是按轮次记账的，
不需要给结果 TSV 加列。具体：
- `run.sh` 新增 `--release-tag <tag>`（默认稳定选择器 `releases/latest`）；只有选中的 case
  真的声明了 `release-*` 输入时才解析（与 npm 输入同一条纪律：**没选就不联网**）；
- 解析结果写 `$run_dir/input-release.tsv`（selector／resolved tag／prerelease 标志／解析时刻），
  `verify` 时随轮次一起留档（`rounds/<id>/input-release.tsv` + `round.tsv` 的
  `release_selector`/`release_instance`/`release_prerelease` 三键）；
- 报告头打印 `发布物实例: <selector> → <tag>（prerelease=…）`——"报告不能只写 case PASS"由此落地；
- 解析失败 → 声明 `release-assets` 的 case 记 **UNMET**，**绝不回退稳定版**（那会得出"认证了
  稳定渠道"的结论而实际什么都没认证）；
- 环境变量 `DSH_RELEASE_SELECTOR` / `DSH_RELEASE_TAG` 作为契约变量钉进 case 环境；
- 护栏：`tools/smoke-runner.sh` 场景 6（非法 tag → 该 case UNMET、独立 case 照跑、且**不写**
  实例记录）。

**依据**：本轮顾问裁决（avemujica `gpt-6-astra`, effort high）。旧 r2 的 `--tag` 是 prerelease
的**唯一**认证入口，而 `releases/latest` 按定义看不见 prerelease；`setup-install/channel`
只管 npm dist-tag，两条 `candidate-artifact` 管的是**未发布**的 workflow 产物——都不继承它。

---

## ADR-012 shebang 不是可移植性机制：契约是"谁执行它"

**决定**：受跟踪脚本（`run.sh`/`serve.sh`/`tools/*`/`cases/*`/`lib/*`/`scripts/*`/
`build/*`）的**契约是显式调用**——`bash <file>`、`exec bash <file>` 或 `source`；
**shebang 不承担可移植性**。而**会被内核直接执行 / 经 PATH 调用**的（生成）可执行文件，
必须在其**目标主机**上使用**字面绝对路径**解释器。

**依据（三条实测，别凭直觉）**：
1. 内核解析 `#!` 后那段**只认字面绝对路径**：不走 `PATH`，**也不做变量展开**。设备上
   实测三条对照——`#!/usr/bin/env bash` 失败、字面 `#!$PREFIX/bin/bash` 失败、
   展开后的绝对路径正常。因此 **`#!$PREFIX/bin/env bash` 不是修法**（`$PREFIX` 不会被展开）。
2. 设备上 **`/usr/bin/env` 这条路径不存在**（`env` 本身在 `$PREFIX/bin/env`），所以
   `#!/usr/bin/env bash` **只在被直接 exec 时**才现形——`bash -n`、shellcheck 与静态检查
   都看不见它。这也解释了为什么它至今没炸：**没有一处直接 exec 受跟踪脚本**。
3. **退出码不是契约**：直接执行实测 126（`bad interpreter`），经 `timeout` 之类包装后
   外层可能看到 127。断言别写死数字。

**刻意不做**：
- **不做全仓 shebang 替换**——会在 CI 与设备之间制造并不存在的差异，并让"统一成一个
  绝对路径"这种**错误**修法看起来可行；两边**没有**共同的绝对解释器路径。
- **不加"按文件名/扩展名/执行位猜谁会被直接执行"的静态护栏**——这些信号**都证明不了
  "永不直接 exec"**；一个 `bash <file>` 调用点排除不了另一个调用者（变量路径、`eval`、
  包装脚本、被复制/重命名、外部调用者）。方向性上：**假阴性更糟**（真机断裂却能过必需的
  CI），假阳性则会以"挡住 PR"的压力逼人关掉护栏。现有护栏（`bash -n` ＋ shellcheck
  `-s bash` ＋ CI 真跑 ＋ 假 `gh` 冒烟）已覆盖真正会现形的那条路径。

**现状核对（本 ADR 写作时）**：22 个 `#!/usr/bin/env bash` ＝ 16 个 `cases/*.sh`
（由 `run.sh` 经 `sandbox_exec` 的 `"$bash_bin" "$1"` 执行，显式解释器）＋
`lib/{patchset,probes}.sh` ＋ `scripts/patch-lib.sh`（只被 `source`）＋
`.github/scripts/` 三个（两处都是 `bash <file>` 调用；**注意它们并非"只在 CI"**——
`patch-matrix.sh` 明确支持 Termux，`package-runtime.sh` 的 stage/verify 也在设备上真跑过）。
**真正被内核直接执行的都是绝对路径**：`dsh` wrapper 与 `$BROWSER` opener
（`scripts/common.sh:208/283`）、沙箱 `grun`（`lib/sandbox.sh:67-69`，位于 PATH 首位）、
生成类先例 `cases/release-install-download-path.sh:115` 的 `#!${BASH:-<绝对路径>}`。
**结论：当时无一处存在真实（或理论上的）设备缺陷，因此本 ADR 不伴随任何 shebang 字节改动。**

**操作契约的记载位置**：`.test-install/README.md` 的「shebang 与"怎么调用脚本"」一节
（唯一一份）；本 ADR 只留"为什么"。收尾的第 10 项重写文档时链过去，**不另做清单**。

**给生成物的具体规则**：在**执行主机上生成时**解析解释器（本仓库既有两种写法：
`#!${BASH:-<Termux 绝对路径>}` 与 `printf '#!%s\n' "$(command -v bash)"`）；
**不要把生成脚本跨主机复制**。`command -v bash` 在常规环境下够用，但严格说可能命中
函数/别名/相对路径；真要收紧就用 `type -P bash` 并校验是绝对、无空白的可执行路径——
**当前没有观察到的缺陷 justifying 这一步**。最后：**为 Termux 构建的产物必须保留 Termux
的解释器**，即使构建发生在 Ubuntu 上，也不能把 CI 的 bash 路径烤进去。

---

## ADR-013 注入式故障实验：同配置双控制 ＋ 精确命中记账

**决定**：凡"某阶段失败后系统仍安全"这类**无法自然复现**的契约，用**沙箱内窄作用域
failpoint**做成可复现实验；实验必须自带**同配置双控制**，并把"是否真的命中"当作
**框架故障**而不是结论来判。

**注入的边界（宁窄勿假）**：
- **只拦一次调用**，且拦的是**真正产生副作用**的那一次——例如补丁管线里
  `dsh_apply_patch` 那次**正向、非 `--check`、非 `--reverse`** 的 `git apply`
  （`scripts/patch-lib.sh:85`）。`--check`／`--reverse`／`rev-parse`／`hash-object`
  与**任何别的 `-C` 目标**一律**透传真实命令**。
- **身份固定**：目标工作树与补丁文件都必须匹配（工作区 `patches/` 下的真实文件），
  否则该次调用不拦——避免"命中了一个恰好长得像的调用"。
- **生产脚本零改动**：注入由沙箱 PATH 首位的 shim 承载（`lib/sandbox.sh:101` 的钉子）。
- 不伪造上游成功（不假装 npm 成功）、不碰 `--self`。

**同配置双控制（必须属于本 case 自己的实验）**：
- 关注入时：同克隆的第二份被测物、同目标、**同 shim**，真实依赖＋真实处理＋boot 成功，
  且 shim 记录 **0 次命中**（证明 shim 本身不扰动成功路径）。
- 开注入时**必须独立证明**：上游那一步确实成功（如 npm exit 0）、受管内容相对
  "注入已就位、实验尚未开始"的快照**确实变化**、**精确命中 1 次**（命中次数同时要在
  case-facts 里记账）、被测程序**响亮非零**且给出可读原因。
- **不得借用**成功路径 case 的历史结果当控制组。

**归类（这条最容易含糊）**：未命中、提前误触发、命中多次 = **ERROR**（注入/框架故障），
**既不是 PASS 也不是笼统 UNMET**；缺网络/缺目标产物 = **UNMET**；已观察到的契约否定保留 **FAIL**。

**恢复类实验的措辞上限**：恢复只撤注入，**不还原被改写的树、不重建输入**，在同一棵
失败树上重跑成功；这**只**证明"按该步骤可恢复到通过既定探针"，**不**证明失败瞬间可用、
原子性、自动回滚、功能完整或任意中断无损。另须有一条断言证明**失败瞬间确实是降级状态**
（否则"程序仍能报版本"会被读成"这次失败无害"）。

**落地**：`update/post-install-patch-failure-recovery`（7f，真机 37 断言）。退出码用专用值
（97），与真实工具的 0/1/128 及 `timeout` 的 124/137 都不撞。

---

## ADR-014 种子资产存储：内容寻址 ＋ 失败安全的发布 ＋ 记录必须过形状校验

**背景（实测复现的两个缺陷）**：资产原按**固定资产名**写进**一个扁平目录**
（`seed-assets/dsh-termux-runtime.tar.gz`），而发布资产名是**跨 tag 固定**的。于是：

1. **跨种子覆盖**：pin `stable`=tagA → pin `other`=tagB 会**静默覆盖** tagA 的字节；两个
   `.env` 都在，**外观上"并存"、字节上已被覆盖**——ADR-004 在**记录层**成立、**字节层**被违反。
2. **单种子也会坏**（不依赖多种子）：`.part`→`mv` 是**逐资产**原子的、不是**每颗种子**原子的。
   re-pin 时资产 1 已 `mv`、资产 2 下载失败 → `.env` 仍是**旧 pin** 而旧字节已变 → 先前全绿的
   种子变红，且**两个 tag 都没有有效 pin**。

**决定**（顾问 `gpt-6-astra` 裁决 ＋ 维护者拍板；前者还指出"内容寻址本身**不**兑现 ADR-004，
若 `.env` 被就地覆写"）：

- **内容寻址**：资产存 `seeds/seed-assets/<sha256>/<资产名>`。**内容决定路径**，所以内容不同的
  资产永不互相覆盖、同一份内容天然去重。
- **失败安全的发布**：私有 staging → 逐件校验 → **只新增**对象 → **最后**才写 `.env`。
  一次失败或中断的 pin **绝不动已有种子**；中断遗留的 staging 按 PID 清扫并被信号 trap 收掉
  （trap 必须**清理并终止**：只 `rm` 不 `exit` 会让"被 SIGTERM"变成"跑完并以 0 退出"）。
- **占用名下换 pin 默认拒绝**（`--force` 只用于重发**同一个** tag）。理由见 ADR-004 的补记：
  要保留的是**旧 pin 记录仍可用**，而"孤儿字节"没有版本关联、不算旧种子。工具原先
  "可原地推进 `stable`"的文档**同步改**，否则等于静默废掉 ADR-004。
- **路径不是信任依据，`.env` 也不是**（安全修复，双评审各自独立复现）：条目里的"资产名"会被
  拼成路径，而 `.env` 是普通文本。一个越界条目（`SEED_ASSET_1=../../victim/x:<匹配的 sha>`）
  曾让新增的 `seed migrate` 把**库外**文件 `mv` 走、甚至 `rm` 掉——**这是本次改动引入的新能力**
  （旧代码只读哈希）。修法是**在构造函数里强制**、不是靠注释或调用方自觉：唯一的记录解析器
  只接受**纯 basename** 资产名（无 `/`、无 `..`）＋ 64 位小写十六进制 sha；`seed_cas_path`
  自己**再拒一次**；不合格条目判为**事实源损坏**，绝不参与路径拼接。
- **存在性不是完整性**（复评抓到的**数据损失**缺陷，安全组据此对 `21f8d9f` 判 BLOCK）：
  `seed_migrate_legacy` 在 CAS 目标**已存在**时只判 `[ -f "$dst" ]` 就 `rm -f "$src"`，从不比内容。
  可目录名就是哈希——内容被损坏时（截断/坏盘/手工改动），唯一还与 pin 相符的字节恰是那份旧
  扁平文件，于是**"修复"命令把它删掉、还打印"归位"记成功**，状态从可修复(FAIL=1)退化成
  无从恢复(UNMET=3)。现在与 `seed_install_cas` 同判据：**内容相符才丢旧副本，不符则保留并报错**。
  推广：**任何删除动作的依据必须是内容比对，不是"目标已存在"**。
- **一条完整性规则必须在每个入口都成立**（复评的 claim 5）：`seed_load` 要求事实源至少有
  一条资产记录、且 `SEED_TAG`／`SEED_DSH_VERSION` 齐备，但 `seed_present` 与 `seed_verify`
  曾只查前者的一部分 → `run.sh seed list` 对一颗**任何 case 都消费不了的种子**报
  "资产齐、哈希相符"。三处现在判据完全一致（零条目、缺字段一律 ERROR），
  这也是 `state.sh` 委托 `seed_present` 的意义所在。
  推广：**修分类分歧要按"全部触发条件"修，不是按"报告里举的那一个例子"修**。
- **四分返回码归一到一处**：`0` 全好 / `1` **FAIL**（对象在、现算与 pin 不符）/ `2` **ERROR**
  （事实源或校验自身坏）/ `3` **UNMET**（缺事实源或缺对象）。严重度序（ERROR > FAIL > UNMET）
  只能有一份实现（`seed_worst`）——UNMET 数值最大但**最轻**，不能用算术取 max。
  **这不是放松判据**：它落实的是 ADR-003 早已写死的分类（"预先声明的种子缺失 → UNMET"、
  "hash 与 pin 不符 → FAIL"）；旧代码把"缺件"也返回 FAIL 反而是**与 ADR-003 矛盾**。
  `UNMET → 退出码 3 → 结论 INCOMPLETE`，只有 PASS 给 READY（矩阵见 README）。

**分层**：存储布局与记录形状的**唯一**定义在 `lib/seed.sh`（`seed_cas_path` / `seed_records` /
`seed_rec_parts`）；`state.sh` 的前置判定**委托**它的 `seed_present`，不再自己拼 `<sha>/<名>`
（委托前实测过一处**分类分歧**：损坏的事实源在门禁处判 UNMET(1)、在加载器处判 ERROR(2)）。
发布流程整体是 `lib/seed.sh` 的 `seed_publish`，`run.sh` 只做参数与 dispatch
（原先塞在 `run.sh` 里，把一个 ~954 行的文件推过 1000 行）。

**边界（照此措辞，别读强）**：这套机制保证的是"**同一台机器上的本地存储**不被自己的工具
破坏"。它**不**保证上游发布资产本身不变（发布者可重发同名资产；恢复必须与旧 pin 相符，
**绝不**用新下载的字节回写 pin），也**不**提供自动 GC（`seed rm` 只删事实源，CAS 对象不自动
回收）。**修复本身仍是待人类实测**——见 STATUS 第 12 项的提示块。

**回归**：`tools/smoke-runner.sh` 场景 8（内容寻址、失败/中断不破坏已有种子、占名拒绝、
migrate 归位、staging 清扫、**形状校验/路径穿越**、**真实 `seed_publish` 被 TERM 时以 143 退出**、
**坏 CAS 目标占位时 migrate 不得删掉唯一与 pin 相符的旧副本**、**零条目/缺 `SEED_DSH_VERSION`
的事实源在 `seed_present`／`seed_verify`／`seed_load` 三处判据一致**），
带反证：两份假发布物内容确实不同；活进程的 staging 不许被误删；把产品里的 `exit 143` 删掉，
该断言**必须变红**；穿越夹具的 `..` 层数必须**实测对齐**（曾少写一层，导致"不得移动库外文件"
这条断言对未修复的库**照样通过**——空转的护栏比没有护栏更糟，因为它提供虚假的安心）。

**评审记录**：首轮双评审判 BLOCK（四条 blocker，`21f8d9f` 修掉）；**修复本身又复评一轮**
（`81a455e`／`f8e1abc`）：安全组仍判 BLOCK（抓到上面那条**数据损失**），质量组 CLEAR。
复评的四类问题——数据损失、门禁分歧的另一半、**空转的穿越断言**、信号场景吃掉 CI 预算
（42s→19s）——全部属于"改这些缺陷时新引入或没改全"，只审原始改动会漏掉。
**结论：修复必须与原始改动同等审阅，不能当作"已审过"一笔带过。**

---

## 实查更正（进入重建依据的事实，已逐条对照源码核实）

| # | 事实 | 证据 | 影响 |
|---|---|---|---|
| C1 | R3 **不是** `00-setup.sh` 的 E2E：它按步调 01→04，并手工复制了 00 的 Bundling 段 | `routes/r3-setup.sh:93-95` 自述 | 方案 B 的**真实入口零覆盖** → 新 case `setup-install/full-pipeline` 必须真的执行 `00-setup.sh` |
| C2 | R3 无条件依赖基线，尽管并不使用基线资产 | `routes/r3-setup.sh:15` | 基线成了无关路线的拦路虎；新 case 必须把"前置"声明化 |
| C3 ~~（✅ 已解决，ADR-010）~~ | `serve.sh` 的 `TAG=` 模式先 `r2 --tag` 认证发布物，**随后无条件 overlay 工作区补丁** | `serve.sh:171-177` + `191-212` | 人类实测对象已不是被认证的产物 → 新 serve **只启动冻结对象**，不生成/不修补/不覆盖 |
| C4 ~~（✅ 已解决，ADR-008）~~ | `live_sentinel` 只检查线上 **node 二进制**的四元组 | `sandbox-lib.sh:130-146` | 证明不了 `~/.dsh`/`~/.bashrc`/wrapper 未被触碰 → 现在是**全路径**签名 + 白名单/父环境两套基底 |
| C5 ~~（✅ 已解决，7f）~~ | 更新器**先原地 npm 装**，补丁失败才退出，树已被改变 | `update-dsh.sh:666` → `675-680` | AGENTS 旧文「响亮停下所以没人拿到坏安装」不成立 → 补上失败/恢复状态机覆盖：`update/failure-recovery`（写入**之前**的失败/中断）＋ `update/post-install-patch-failure-recovery`（**npm 成功改写树之后**补丁失败，7f，真机 37 断言）。**注意生产行为未变**：本项补的是**覆盖**，不是修 `update-dsh.sh` 的顺序问题——"先原地装、补丁失败才退出"依然存在，只是现在有可归属的证据说明它失败后可恢复，且该证据的边界被显式写窄（见 STATUS）。 |

**另需更正的一处表述**：旧体系并非"没有运行验证"——CI 的 `patch-check.yml`
确有 boot smoke（x64）。准确缺口是：**缺"工作区内容 × 精确目标版本 × 真实 arm64
环境"的可归属、可重复验证**，以及分支候选产物与其安装路径的同源验证。

---

## 附录 A：旧断言 → 新 case 迁移映射（第 7a 步产物）

> **状态（2026-09-15 收官）：本表是第 7a 步的历史产物，用途已完成。**
> 第 11 项"删除旧 `routes/`、`sandbox-lib.sh`、`baseline.env`"**已落地**，四个旧路径**已从盘上
> 删除**；表内所有「缺口 → 7b/7c/8/11」都已在后续步骤补齐（探针库、L8/L9/L10 迁入
> `lib/patchset.sh`、registry `requires` 修正、ADR-011 输入实例记账）。**L3 的"有意不继承"是
> 决定、不是欠账。** 所以：**不要把表里的「缺口」当作待办**——它记录的是"当时每条缺口是怎么
> 被识别出来的"。仍然有效的是**删除依据**本身；表内旧文件坐标（`sandbox-lib.sh:NN` 等）是
> **删除前**的位置，已不可跳转。
>
> 规则：一条旧断言只有在"新体系里谁负责它"写明之后才允许随旧文件删除；找不到归属的
> 写「缺口」并挂到具体步骤。**"新体系看起来差不多了"不是删除理由。**
>
> 状态口径：**继承**＝同一契约在新体系有归属；**继承（加强）**＝新归属更严或覆盖面更大；
> **改判**＝有意换做法（附理由）；**缺口**＝当时尚无归属。
> 规模：旧 r1–r6 共 **52** 个断言组（`ok` 站点）＋公共能力 **14** 项 ＋ 行为探针 **3** 个。

### A.1 公共能力（`sandbox-lib.sh`；旧 `run.sh` 的路线分发已被整体替换）

| # | 旧单元（位置） | 新归属 | 状态 |
|---|---|---|---|
| L1 | 基线事实源加载＋四键完整性（`:35-46`） | `seeds/<name>.env`＋`state_check_require seed:*`（`lib/state.sh:125-139`） | 继承（`baseline.env`→`seeds/`，ADR-004） |
| L2 | 基线资产 sha256 强校验（`:49-59`） | `seed_verify`（`lib/seed.sh:127-146`，`seed show` 打印）＋**消费种子的 case 必须在 case 体内核对哈希**（`lib/state.sh:117-118` 明确把哈希留给 case） | 继承（须由 case 落实，否则退化成"只查存在性"） |
| L3 | 仓库 `VERSION` vs pin 漂移 **WARN**（`:62-72`） | **无归属，且不需要**：ADR-004 已撤销"发版后必须 re-pin"与"旧种子随之淘汰" | 改判（有意不继承） |
| L4 | 唯一 unset 清单 `env_sanitize`（`:77-82`） | ADR-010 两套环境基底：`lib/sandbox.sh:97-233`（case 白名单／serve 父环境） | 改判（`env -i`＋白名单在结构上消灭"忘了清某个变量"） |
| L5 | `grun` stub（`:84-88`） | `sandbox_write_grun_stub`（`lib/sandbox.sh:66-70`） | 继承 |
| L6 | `sandbox_init`：目录／HOME／TMPDIR／DSH_*／PATH／flock（`:94-123`） | `sandbox_prepare`／`sandbox_teardown`／`sandbox_case_name`（`lib/sandbox.sh:53-70,234-278`） | 继承（加强：沙箱名由 case id 派生；并发冲突从"互删"改成显式报错） |
| L7 | `live_snapshot`／`live_sentinel`：线上 **node 二进制**四元组（`:125-147`） | 全路径签名＋**每条 case 前后**（`lib/sandbox.sh:24-51,288-326`；`run.sh:397-419`） | 继承（加强，C4） |
| L8 | `wrapper_hook_expected`／`assert_wrapper_hook`（`:156-164`） | **无归属** | **缺口 → 7c**（update 类 case 需要；锚点串与 `common.sh` 逐字耦合的旧风险照旧） |
| L9 | `shipped_patch_entries`／`patch_entry_marker`／`patch_entry_precondition`／`marker_for_patch`：解析**产物内**注册表（`:174-209`） | **无归属** | **缺口 → 7b/7c/11**：三个探针的 marker 派生、`release-install/shipped-release`、`update/shipped-updater`、`update/refresh-machinery` 的期望值全依赖它；不迁走就删不掉 `sandbox-lib.sh` |
| L10 | `overlay_workspace_patches`：先退 shipped 集、再打工作区集（`:223-244`） | `dry-run/pinned-rebase`（待写）**＋ CI `.github/scripts/patch-matrix.sh:29,163` 仍在直接调用它** | **缺口 → 7c/11**：删 `sandbox-lib.sh` 前必须连 `patch-matrix.sh` 一起改锚，否则 `verify.yml` 的「补丁适用于每个我们服务的 dsh build」一步直接断 |
| L11 | 三个行为探针（`:258-441`） | 7b 移植，**证据等级 marker→behavior** | **缺口 → 7b** |
| L12 | `resolve_release_tag`／`fetch_release_assets`（`:451-492`） | `lib/seed.sh:34-98`（`seed set` 的唯一实现；"绝不 `wget -c` 续传"的教训原样保留） | 继承 |
| L13 | `ok`／`fail`／`note`／`warn_record`／`summary` 计数（`:15-27`） | `lib/state.sh:65-92` 状态协议（PASS/FAIL/UNMET/NOT_APPLICABLE/ERROR）＋聚合 | 改判（`warn_record` 的"集中 WARN 区"没有继任者：降级信号现在必须落成一个状态，否则就是"没这条"） |
| L14 | 环境变量旋钮 `DSH_SANDBOX`／`DSH_UPDATE_TAG`／`DSH_R4_TAG` 等（`:81`＋各路线） | 参数一律 `--flag`；旧写法**硬拒绝**（`serve.sh` 的 `legacy_guard`） | 改判（ADR-010；`DSH_R4_TAG` 别名有意不继承） |

### A.2 R1 基础安装 → `release-install/workspace-installer`／`dry-run/pinned-rebase`

| # | 旧单元（位置） | 新归属 | 状态 |
|---|---|---|---|
| R1.1 | `install.sh` 退出 0（`:18-22`） | `release-install/workspace-installer` | 继承 |
| R1.2 | 覆盖重装：旧嵌套包与孤儿被清空＋非 tarball 文件保留＋npm 模块链可 `require`（`:24-48`） | 同上（registry 契约已写明 including overwrite-reinstall） | 继承 |
| R1.3 | `install.sh` 不含复制逻辑（`:50-57`，7 个模式） | CI `verify.yml:246-271`「Verify install.sh delegates to common.sh」 | 继承（加强：另加正向 `source`／调用断言与 `--set-rpath` 陷阱；**小缺口**：CI 未覆盖旧清单里的 `ask_yes_no()`） |
| R1.4 | node ELF interpreter ＝ glibc loader（`:59-62`） | `release-install/workspace-installer` | 继承 |
| R1.5 | 补丁后 node 可直连运行（`:63-70`） | 同上；`dry-run/pristine-npm` §3 另已独立覆盖"01 装出的 node 可执行" | 继承 |
| R1.6 | wrapper 直连 exec；版本 ＝ 种子 dsh 版本（`:72-77`） | 同上 | 继承 |
| R1.7 | opener 在场＋无参 exit 2（`:79-84`） | 同上 | 继承 |
| R1.8 | symlink 指向 wrapper 且可运行；`.bashrc` tag＋PATH 注入（`:86-92`） | 同上 | 继承 |
| R1.9 | 工作区补丁集可 overlay 到基线树（含 marker 验证）（`:94-103`） | `dry-run/pinned-rebase`（行为级）＋ CI `patch-matrix.sh` 第二段（秒级回归） | 继承（双份，各有用途；见 L10） |
| R1.10 | `live_sentinel`（`:105-106`） | 框架 live-guard | 继承（加强） |

### A.3 R2 发布物认证 → `release-install/shipped-release`

| # | 旧单元（位置） | 新归属 | 状态 |
|---|---|---|---|
| R2.1 | 解析 latest＋**全新**下载两个资产（`:34,40-46`） | `lib/seed.sh` 的 `resolve_release_tag`／`seed_fetch_assets`（即 `seed set`）；case 读 `release-assets` | 继承 |
| R2.2 | tarball 关键成员清单（6 项）（`:48-58`） | `release-install/shipped-release` | 继承 |
| R2.3 | tarball 顶层 `VERSION`（存在才断言，旧 release 不误红）（`:59-65`） | 同上（条件保留） | 继承 |
| R2.4 | shipped `DSH_PATCH_SET` 自洽：声明的补丁文件与目标 lib 都在 tarball 里，且 ≥1 条（`:66-80`） | 同上（依赖 L9 的解析器） | 继承 |
| R2.5 | shipped `install.sh` 安装退出 0（`:82-87`） | 同上 | 继承 |
| R2.6 | shipped 补丁 marker（`precondition` 感知）（`:89-107`） | 同上 | 继承 |
| R2.7 | shipped 原生件在场（`native_prebuild_entries`；该版本不用则跳过）（`:109-122`） | ~~`release-install/shipped-release`~~ | **已下线（11b）**：ADR-001 判定原生件机制对支持版本全部空转，代码与断言一起删除；那条断言本来也拿**工作区**注册表判 **shipped** 产物，不是被测对象的属性 |
| R2.8 | 三个行为探针（shipped marker 条件触发）（`:124-133`） | 7b | 缺口 → 7b |
| R2.9 | node 补丁＋可运行（`:135-141`） | 同上 | 继承 |
| R2.10 | wrapper execs dsh；浮动模式**从安装树自读**期望版本（`:143-156`） | 同上 | 继承 |
| R2.11 | opener 无参 exit 2（`:158-163`） | 同上 | 继承 |
| R2.12 | symlink＋`.bashrc` 注入（`:165-171`） | 同上 | 继承 |
| R2.13 | `live_sentinel`（`:173-174`） | 框架 | 继承（加强） |
| R2.14 | `--pinned` 离线回退：pin 资产＋期望版本＝pin 的 dsh 版本（`:28-32,147-152`） | `baseline-seed`／`release-seed` 具名输入＋`seed:stable` 前置 | 继承（改名 pin→seed） |
| R2.15 | `--tag <tag>`：**pre 渠道发布物**的认证入口（`:19-26,34-36`） | `release-install/shipped-release` 的**具名输入实例**（默认稳定选择器，可显式指 pre；不新增 case） | 改判（**已裁决：ADR-011**） |

### A.4 R3 setup 管线 → `setup-install/full-pipeline`＋`dry-run/pristine-npm`

| # | 旧单元（位置） | 新归属 | 状态 |
|---|---|---|---|
| R3.1 | 真机 glibc 前置：`grun`＋`dpkg` 三包（`:18-26`） | `requires host:glibc`（`lib/state.sh:143-159`：grun／patchelf／glibc／glibc-repo） | 继承（加强：多查 `patchelf`） |
| R3.2 | [01] 官方 node＋glibc 补丁＋可运行（`:39-45`） | `dry-run/pristine-npm` §3（走真实入口） | 继承 |
| R3.3 | [02] npm 装 dsh（`--ignore-scripts`）（`:47-52`） | `dry-run/pristine-npm` §4-5，并新增 SRI 闭环 | 继承（加强，ADR-009 证明链） |
| R3.4 | [03] 补丁 marker（`precondition` 感知，工作区全集）（`:54-74`） | `dry-run/pristine-npm` §6，并新增"独立复核适用性"＋树身份变化 | 继承（加强） |
| R3.5 | [04] wrapper／opener／symlink／bashrc（stdin 答 y,n）（`:76-91`） | `setup-install/full-pipeline` | 继承 |
| R3.6 | 00 的 runtime 自含段：`scripts/`＋`patches/`＋`VERSION` 进 runtime，与 Option A 布局归一（`:93-115`） | `setup-install/full-pipeline` | 继承（加强，C1：走**真实** `00-setup.sh` 入口，不再手工复制该段） |
| R3.7 | `live_sentinel`（`:117-118`） | 框架 | 继承（加强） |
| R3.8 | 无条件 `load_baseline`（基线成为无关路线的拦路虎）（`:15`） | `requires` 声明化 | 改判（C2，有意不继承） |
| R3.9 | `DSH_NODE_VERSION` 旋钮（`:29`，实测取值与 01 默认同值） | 直接用 01 的 `NODE_VERSION` 文件默认；case 把实测 node 版本记进 `case-facts` | 改判（覆盖无损失：旧值本就等于默认值；生产仍可用 `DSH_NODE_VERSION` 覆盖） |

### A.5 R4 工作区更新器 → `update/workspace-updater`（＋`update/refresh-machinery`）

| # | 旧单元（位置） | 新归属 | 状态 |
|---|---|---|---|
| R4.1 | 基线 tarball 种子旧 runtime（node 未补丁）＋读种子版本（`:37-43`） | `update/workspace-updater` | 继承 |
| R4.2 | 工作区 `update-dsh.sh -t <tag> -y` 退出 0（`:45-48`） | 同上 | 继承 |
| R4.3 | node 补丁仍在＋可运行（`:50-54`） | 同上 | 继承 |
| R4.4 | 经重写 wrapper 取版本；版本变则记 `BEFORE→AFTER`，未变则 note（机制仍验）（`:56-67`） | 同上 | 继承 |
| R4.5 | 工作区注册表全集 marker（`precondition` 感知）（`:69-87`） | 同上 | 继承 |
| R4.6 | 三个行为探针（`:89-96`） | 7b | 缺口 → 7b |
| R4.7 | opener＋symlink 重写可用（`:98-106`） | 同上 | 继承 |
| R4.8 | update 钩子符合**生成器能力**（`:108-110`） | 同上＋`update/wrapper-entry` | 缺口 → 7c（依赖 L8） |
| R4.9 | 钩子目标＝**runtime 内置**更新器（Option A 优先级，不得指回 checkout）（`:112-117`） | `update/workspace-updater` 的 case 体 | **缺口 → 7c**：registry 契约未提；这是"用户真实路径"的关键一条，不得丢 |
| R4.10 | 自动刷新分支：假旧 `VERSION`→判定落后→下载补丁集资产→re-exec→继续 npm 并完成＋已安装注册表 marker＋wrapper 钩子（`:119-148`） | `update/refresh-machinery` | 继承（**registry `requires` 需补 `network:github`**） |
| R4.11 | `live_sentinel`（`:150-151`） | 框架 | 继承（加强） |
| R4.12 | `DSH_UPDATE_TAG`／`DSH_R4_TAG` 选 tag（`:25`） | 具名输入；旧 env 名硬拒绝 | 改判（见 A.8） |

### A.6 R5 发布物内置更新器 → `update/shipped-updater`

| # | 旧单元（位置） | 新归属 | 状态 |
|---|---|---|---|
| R5.1 | 下载 latest release 作种子（`:23-28`） | `update/shipped-updater`（`release-seed`） | 继承 |
| R5.2 | 种子解包＋读版本＋**内置更新器必须在场**（缺则红，打包回归）（`:30-39`） | 同上 | 继承 |
| R5.3 | shipped 补丁文件齐全＋≥1 条＋生成器钩子能力（`:40-51`） | 同上（依赖 L9／L8） | 继承 |
| R5.4 | shipped `--self` 全链路：假旧 VERSION→`1.1.0`→shipped＋补丁声明不缩水＋re-exec（`:53-80`） | `update/shipped-updater` | **归属待定 → 7c**：主体是**发布物内置**更新器（下载 ~40KB 补丁集资产），与工作区 `--self` 是两份实现；按 ADR-009"资格绑定主体／工作区结论不得外推为 shipped 已验证"，应留在这条 case 内；registry 需补 `network:github` |
| R5.5 | shipped `update-dsh.sh -t <tag> -y` 退出 0（`:82-85`） | 同上 | 继承 |
| R5.6 | node 补丁仍在（`:87-91`） | 同上 | 继承 |
| R5.7 | 更新后版本（`:93-104`） | 同上 | 继承 |
| R5.8 | shipped marker（`precondition` 感知）（`:106-123`） | 同上 | 继承 |
| R5.9 | 三个行为探针（`:125-134`） | 7b | 缺口 → 7b |
| R5.10 | opener＋symlink 重写（`:136-144`） | 同上 | 继承 |
| R5.11 | 钩子符合 shipped 生成器能力（`:146-147`） | 同上（依赖 L8） | 继承 |
| R5.12 | `live_sentinel`（`:149-150`） | 框架 | 继承（加强） |

### A.7 R6 `--self` 与本地补丁集 → `update/self-patch-set`（＋`update/refresh-machinery`）

| # | 旧单元（位置） | 新归属 | 状态 |
|---|---|---|---|
| R6.A | `--self --patch-set <本地目录>`：装 scripts＋**先退旧集**＋应用新集＋全程无 npm＋VERSION 更新＋marker＋wrapper 重写可运行（`:67-90`） | `update/self-patch-set` | 继承 |
| R6.B | 机件签名相同→报告已最新、不重打、exit 0（`:92-101`） | 同上 | 继承 |
| R6.C | `--force` 重打＋`-t/-v` 忽略提示＋无 npm（`:103-115`） | 同上 | 继承 |
| R6.D | 本地现打 tarball 消费：成员清单＋staging 提示＋应用＋marker（`:117-135`） | 同上（`changes` 已含 `build/build-patchset.sh`） | 继承 |
| R6.E | 负例：注册表声明的补丁文件缺失→响亮失败且**未触碰 runtime**（`:137-153`） | 同上 | 继承 |
| R6.F | 安装的 updater 不认识哨兵→子 shell 回退应用（`:155-173`） | 同上 | 继承 |
| R6.G | 下载路径：`--self` 从 latest release 资产刷新并应用（无 npm）（`:175-191`） | 同上（**已落地**：不带 `--patch-set` 的 `--self` 是同一契约的另一个输入来源；registry 已补 `baseline-seed`＋`seed:stable,host:glibc,network:github`） | 继承 |
| R6.H1 | `DSH_PATCHES_CHANGED=1`→明示＋停止提示＋答 n 中止＋"补丁未应用" NOTE（exit 1）（`:199-211`） | `update/refresh-machinery` | 继承 |
| R6.H2 | 无 `DSH_PATCHES_CHANGED`→中止干净、无 NOTE（`:213-222`） | 同上 | 继承 |
| R6.I | `verify_markers` 助手：子 shell 里 source 指定注册表再验 marker，防污染（`:44-65`） | `update/self-patch-set` 的 case 体 | 继承（实现细节） |
| R6.J | `live_sentinel`（`:225-226`） | 框架 | 继承（加强） |

### A.8 旧输入旋钮 → 新具名输入／参数（ADR-009「其余消费者的输入审计」）

| 旧旋钮 | 消费者 | 新形态 | 状态 |
|---|---|---|---|
| `DSH_VERSION`（npm spec） | `02-install-dsh.sh`（r3） | 具名输入 `default-target`：精确 spec＋SRI＋tarball，逐轮冻结 | 继承（加强，ADR-009 三层之②） |
| `DSH_UPDATE_TAG`／`DSH_R4_TAG` | r4／r5／r6 驱动 | 更新目标 dist-tag 的具名输入 | **缺口 → 第 8 项**（ADR-009 已排期："updater 的 `TARGET` 传递与 re-exec"）；旧 `DSH_R4_TAG` 别名不继承 |
| 发布物 tag（`--tag`／`--pinned`） | r2／r5 驱动 | `release-assets`／`release-seed`／`baseline-seed` 具名输入 | 部分：稳定与 pin 已就位；**pre tag 见 R2.15（待顾问复核）** |
| `DSH_SANDBOX` | r3／r4／r5／r6 驱动 | 沙箱名由 case id 派生 | 改判（不再共享沙箱；并发冲突从"互删"改为显式报错） |
| `DSH_NODE_VERSION` | r3 驱动 | 01 的 `NODE_VERSION` 文件默认（生产仍可覆盖） | 改判（R3.9） |
| `DSH_RELEASE`／`DSH_REPO`／`DSH_CANDIDATE_ARTIFACT` | `install.sh`／workflow | `release-install/download-path`；`artifact:branch-candidate` 前置 | 继承 |
| `WITH_CREDS`／`REUSE`／`NO_OPEN` 等 | 旧 `serve.sh` | `serve.sh --with-creds`／`--round`／`--no-open`；旧 env 写法**硬拒绝** | 改判（ADR-010） |
| `DSH_ASSUME_YES`／`DSH_WEB_PORT`／`DSH_PATCH_SET` | 被测脚本 | 白名单／钉子列表里的契约变量（`lib/sandbox.sh:97-133`） | 继承 |

### A.9 缺口清单（当年挂在 7b／7c／8／11 上——**已全部关闭，非待办**）

> **状态（2026-09-15 收官）：7 条全部落地，本清单已关闭。** 保留它是为了记录"每条缺口当时是
> 怎么被识别出来的"——**不要再照它开新会话或新待办**。
> 1–6：7b 探针库、L8/L9/L10 迁入 `lib/patchset.sh`、R4.8/R4.9/R5.4/R6.G 归属与 registry
> `requires` 修正、`ask_yes_no()` 补进 CI、ADR-011 输入实例记账、更新目标用本轮冻结的 npm 输入。
> 第 7 条：`lib/patchset.sh` overlay ＋ `seeds/*.env` 取代 `BASELINE_*` 两个改锚都已完成，
> 四个旧路径**已删除**；R2.7 原生件下线作为独立的 11b 生产代码提交落地（ADR-001 落地记录）。
> 11b 带回的两个缺口也均已落地：下限检查（11c，`d8af293`）与旧 tarball 安装回归（11d，`69efdf5`）。

<details><summary>原文（历史记录，勿当待办）</summary>

1. **7b ✅（探针库与首个 case）**：`lib/probes.sh` 移植了三个探针（`probe_landlock_tmpdir`／
   `probe_fslocal_link_rename`／`probe_attachment_durability`，聚合入口
   `probe_patch_set_behaviors`），已挂进 `dry-run/pristine-npm`（§6b）。触发 marker **按补丁
   目标 rel 从消费的注册表派生**（旧体系审计 H2 的写死串缺陷不再存在）；跳过与失败都是状态：
   目标不在树/注册表无该目标＝可见的 n/a 并进 `case-facts`，声明了却缺 marker＝**FAIL**
   （旧体系只 warn）。护栏：`tools/smoke-probes.sh`（21 项，进 CI）。**update 类 case 的挂接随 7c**。
2. **✅ L8／L9／L10 已迁**：新库 `lib/patchset.sh` 收下产物内注册表的**文本解析**（`patchset_entries`／
   `_marker`／`_precondition`／`_rel`／`_patch`／`_marker_for_patch`／`_verify_markers`）、wrapper
   钩子能力派生（`wrapper_hook_expected`＋`patchset_wrapper_hook_check`）与 overlay
   （`patchset_overlay_workspace_patches`）。`sandbox-lib.sh` 的 `overlay_workspace_patches`
   改成**薄委托**（一份实现，patch-matrix 无需改动）；护栏 `tools/smoke-patchset.sh`（20 项，进 CI），
   并用 CI 的 `patch-matrix.sh` 对真实发布资产跑过（shipped post-image → 工作区补丁集 rebase 成功）。
   **第 11 项**（历史注：当时仍须把 `patch-matrix.sh` 改锚到 `lib/patchset.sh` 并删掉旧文件）——
   **已落地**（`24a63bf`／`ab334a4`，见 ADR-001 落地记录）。
3. **✅ R4.8／R4.9／R5.4／R6.G 归属已定并落地**：R4.9（钩子不得指回 checkout）在
   `update/workspace-updater` 里补了**否定断言**；R5.4（shipped `--self` 全链路）在
   `update/shipped-updater`；R6.G 在 `update/self-patch-set`（`--self` 不带 `--patch-set`
   是同一契约的另一个**输入来源**，按 ADR-005 不另开 case）。`requires` 已补齐（见 7c 落地记录表）。
4. **✅ 7c（小）**：R1.3 的 `ask_yes_no()` 已补进 CI 的 install.sh 委派守卫。
5. **✅ 已裁决并落地（ADR-011）**：R2.15 pre 渠道 —— 不新增 case，做成
   `release-install/shipped-release` 的**具名输入实例**；`run.sh --release-tag`、
   实例记录进轮次与报告头、解析失败记 UNMET 且不回退稳定版（机制见 ADR-011 末节）。
6. **第 8 项**：更新目标具名输入（A.8）。**（已落地）**
7. **第 11 项**：~~R2.7 原生件随 ADR-001 下线~~（**已做，见 11b 与 ADR-001 落地记录**）；
   `.gitignore` 里的 `!sandbox-lib.sh`／`!baseline.env`／`!routes/` **已撤**；`release-test/`
   （~110MB 旧 pin 资产）**已删**（同一批字节在 `seeds/seed-assets/` 里，sha256 逐字相同）；
   `AGENTS.md`、`CONTRIBUTING.md`、`PATCHES.md`、`.test-install/README.md` 的失效引用**已同步**
   （全文重写已随第 10 项落地）。

</details>

### A.10 非 case 资产与旧入口（同样不能漏）

- **旧 `serve.sh` 的自动层断言**（起 web 前的 overlay 门槛、`TAG=` 模式"先认证发布物再 overlay"
  的 C3 缺陷）：由 **ADR-010 的冻结对象**取代 —— serve 只启动被断言过的那棵树，不再 overlay；
  人工项由 `cases/checklists/*.txt` 承载。旧 `serve.sh` 的"沙箱环境导出"断言由
  `lib/sandbox.sh` 的两套基底＋`tools/smoke-sandbox.sh` 场景 8 继承。
- **`baseline.env`／`release-test/`**：`seeds/*.env`＋`seeds/seed-assets/` 取代（L1／L2／R2.14）。
- **旧 `run.sh` 的路线分发与 `all` 门槛**：新 `run.sh` 的 profile＋退出码取代；交付门槛从
  "r1+r2+r4+r5+r6"变为"`verify` 必需项全 PASS ＋ 人工项同轮终结"。
