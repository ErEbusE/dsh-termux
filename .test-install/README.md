# .test-install/ — 沙箱自动层与人类实测层（操作手册）

> **受众**：跑测试、改测试体系、排查失败的人/代理。协议**不变量**（铁律、Termux 禁忌、token 纪律、判定标准）在仓库根 [AGENTS.md](../AGENTS.md)，本文只承接其**操作细节**。分工是硬约束：**进度**只改 [STATUS.md](STATUS.md)，**决策的"为什么"**只改 [DECISIONS.md](DECISIONS.md)（ADR-001..015、实查更正 C1–C5、附录 A），操作细节只改本文。矩阵的**唯一事实源**是 [cases/registry.tsv](cases/registry.tsv)——**本文一条 case 也不抄**。

```
run.sh      自动层唯一入口: list|validate|check|verify|full|seed|clean
serve.sh    纯隔离沙箱启动器: --sandbox <名> [--port n] [--with-creds] [--no-open]
lib/        内核: state registry seed sandbox receipt inputs patchset probes
cases/      registry.tsv(唯一事实源) + executor + checklists/(人工清单正文)
tools/      维护者工具(整目录纳管)      seeds/<名>.env 种子事实源(入库)
state/      [ignore] receipts/ 是**证据**，clean 保留
sandbox-*/  [ignore] 各 case 的沙箱; 带人工清单的 case 通过后留在这里等人类实测
```

`routes/`、`sandbox-lib.sh`、`baseline.env`、`release-test/` **已从盘上删除**——逐条归属见附录 A（"能力逐项有继承证据"才允许删，不是"新体系差不多就行"）。命令怎么写**以 `run.sh help` / `serve.sh -h` 为准**。

## 快速上手

```sh
bash .test-install/run.sh help                            # 全部命令一屏带注释(权威)
bash .test-install/run.sh validate --strict-executors      # 清单自洽 + executor 齐备
bash .test-install/run.sh list [--format=md]               # case 清单(矩阵表由此生成, 不手写)
bash .test-install/run.sh check -c <case-id>               # 快集: 点选单跑(不授予交付资格)
bash .test-install/run.sh verify                           # 交付裁决(自动层): 按 diff 算必需 case
bash .test-install/serve.sh --sandbox <名>                 # 在隔离沙箱里做人类实测(端口 3141)
```

## 三个 profile 与退出码

| 命令 | 语义 | 授予交付资格 |
|---|---|---|
| `check` | 快集（离线或短网、不依赖大体积种子） | **否** |
| `verify` | **唯一交付裁决**（自动层）：按改动范围算必需 case 并执行 | 是 |
| `full` | 诊断性全量执行 | 否（是执行范围，不是交付标准） |

- 退出码 `0` 必需项全 PASS / `1` 有 FAIL / `2` 有 ERROR（框架或配置故障）/ `3` 有必需 UNMET；聚合优先级 **ERROR > FAIL > UNMET > PASS/N.A.**。UNMET 不是较轻的 WARN：缺**可测对象**（种子没下、设备不在、产物没给）就是没有结论——它**不阻断别的 case**，但**阻断依赖该证据的交付结论**。
- **交付结论（自动层）独立于执行结果**：`READY / INCOMPLETE / REJECTED`——有 FAIL/ERROR = REJECTED、有 UNMET = INCOMPLETE、皆无 = READY。人类实测**不进**这个结论（ADR-003/015）。
- `verify` 必需项 = **diff 命中 ∪ 显式点选**（`--diff-base` 默认 `main`）。**diff glob 看的是整个 PR diff**，所以纯文档 push 也可能让某条 case 变成必需项。

## 证据等级与断言分级

registry 的 `evidence` 列声明**这条 case 主张到哪一层**（写宽了等于虚报）：`marker` 只证明目标文件**变过**（它**不是**行为 oracle）／`behavior` 真实 import 执行被测树／`boot` 能起来／`install` 安装器接线正确／`download` 抓到的字节 == 声明的摘要。

- 条件补丁（前置条件不满足）**跳过不是已验证**，必须写进证据；声明了却缺 marker 是 **FAIL**。
- 期望值一律**派生**：版本 ← `seeds/<名>.env`；补丁清单与 marker ← 被消费的那份 `DSH_PATCH_SET`；wrapper 钩子 ← 生成器能力探测。**任何地方都不许写死补丁列表或版本号。**
- 断言失败即 FAIL，禁止"只跑个大概"；点选即只跑点选的，空选择补 `framework/selection` ERROR，禁止聚合出 PASS。

## 人工实测

**原则：人类实测必须经 serve.sh 的沙箱环境。** agent 交付的实测步骤绝不允许指向本地正在运行的 dsh runtime / `~/.dsh` / `~/.bashrc`（教训：曾两次把清单写成直改本地正在运行的安装，被人肉纠正）；对本地 runtime 的升级只作为最后一步，执行的是沙箱里已验证过的产物。人类实测是**最终判定**，agent 的自动层 PASS 不能代替它（AGENTS.md §0）；凭据在**会话中**报告，最终用 `tools/tb.sh` 写进合并提交的 `Tested-by:`。

```sh
bash .test-install/run.sh verify            # 自动层；带人工清单的 case 通过后保留沙箱并打印下一步
bash .test-install/serve.sh --sandbox <名>  # 在隔离沙箱里逐项照清单实测(端口 3141)
```

- **verify 只跑自动层**：结论纯由自动结果决定，没有人工门（ADR-015）。带人工清单（registry `human` 列）的 case 通过后**保留沙箱**，报告里打印 `bash .test-install/serve.sh --sandbox <名>`。
- **`human` 列只是文档**：它指"这条 case 该由人照哪份清单测"，正文在 `cases/checklists/<id>.txt`；**不再是任何自动门的输入**。一个 case 的清单过没过，由人在会话里说明，不靠自动层记。
- **serve 是纯沙箱启动器**：解析沙箱、校验载荷入口在场、隔离环境（`sandbox_env_human`）、写启动器、起 `dsh web`；不生成内容、不写记录、不做签认。旧版 serve 认证完发布物后**无条件** overlay 工作区补丁，人测到的已不是被断言的那棵（实查更正 C3）——现在沙箱由 agent 装好，serve 只启动它。
- **沙箱边界（铁律）**：实测只在 `serve.sh --sandbox <名>` 起的隔离环境里做，绝不指向本地正在运行的 `~/.local/opt/dsh-termux-runtime/`、`~/.local/bin/dsh`、`~/.bashrc`、`~/.dsh`；`grun` 是 stub，临时文件落沙箱内（Termux 禁访系统 `/tmp`）。细节见本文「沙箱边界」节。
- **环境基底与 case 刻意不同**：case 用 `env -i` + **白名单**（无人值守、可复现）；serve 用**父环境 − 危险项 + 沙箱钉子**（真实用户就是这么跑的——白名单下实测浏览器 4 次全不弹）。两层是**互补证据**，且**不许跨环境抵消**：一个环境里的 FAIL 不能被另一个环境的 PASS 冲掉，诊断开关（`--probe-handoff` / `--strip-android-root`，后者**默认关**）下的成功也不能替代默认环境的人工项。
- **凭据**：`--with-creds` 把本地 `~/.dsh` 的 `.credentials.yaml` + `settings.yaml` 复制进沙箱（值不打印）。**环境变量型凭据不需要这个开关**——serve 用的是父环境，你 shell 里 export 的 provider key（`~/.profile` 里的那些）会原样继承，与真实安装一致（这一点与 case 的白名单环境刻意不同）。**case 永远拿不到凭据。**
- **浏览器交接默认不插桩**：dsh detach 起 xdg-open，spawn 那一刻就返回成功，所以 serve **不对"弹没弹"下结论**，以人看到页面为准（开关与分层结论见 `serve.sh -h`）。
- **证据落点**：实测确认后用 `bash .test-install/tools/tb.sh "<范围>"` 把 `Tested-by:` 写进**合并提交**——git 历史即永久台账（`git log --grep='^Tested-by:'` 可检索），PR 正文保持干净。纯 CI/工作流改动用 `--review`；能落到设备上的改动一律默认 `on-device`（AGENTS.md §6）。

## 种子管理（seeds/<名>.env）

种子 = 某个**已发布**发布物被钉住的那份事实（tag + 各资产 sha256），是大量 case 的输入，纪律是"绝不手编、哈希现算、写盘原子"：

```sh
bash .test-install/run.sh seed list                      # 有哪些种子及资产状态
bash .test-install/run.sh seed show stable               # 打印事实源并逐件核对哈希
bash .test-install/run.sh seed set <tag|latest> [<名>]   # 新增种子(默认名 stable)
bash .test-install/run.sh seed set <tag> <名> --force    # 只用于重钉**同一个** tag
bash .test-install/run.sh seed migrate                   # 旧扁平资产归位到内容寻址存储
```

哈希一律现算，绝不手抄；**绝不 `wget -c` 续传**（代理续传拼出"新包+旧尾"的事故，见 `lib/seed.sh` 头部）；pre 渠道产物不作种子（`seed set` 会拒绝）。

**资产按内容寻址存**：`seeds/seed-assets/<sha256>/<资产名>`。内容决定路径，所以内容不同的资产永不互相覆盖、同一份内容天然去重；读之前一律现算并与目录名核对，不符即响亮失败。**路径不是信任依据，而 `.env` 也不是**：条目里的"资产名"会被拼成路径，所以它必须是**纯 basename**（无 `/`、无 `..`），sha 必须是 64 位小写十六进制——形状校验只在 `seed_rec_parts` 一份，`seed_cas_path` 自己再拒一次；不合格的条目判为**事实源损坏**，绝不参与路径拼接（实测过越界条目曾让 `seed migrate` 把库外文件搬走）。**发布是同址安全的**：先下到私有 staging → 逐件校验 → 只**新增**对象 → **最后**才写 `.env`，所以一次失败的 pin 绝不破坏已有种子；中断留下的 staging 会在下次开跑时按 PID 清掉。发布流程整体是 `lib/seed.sh` 的 `seed_publish`（`run.sh` 只做参数与 dispatch）。`seed migrate` 只把**与某条 pin 逐字相符**的旧扁平资产归位，不改任何 `.env`。

**占用名下换 pin 默认被拒绝**：ADR-004 要求旧种子**保留**（追新 pin 会消灭旧版本的升级覆盖窗口，而"孤儿字节"没有版本关联、不算旧种子）。想上新版本请**换一个名字新增**；只有上游重发同一 tag 的资产时才用 `--force`。

种子变更改变的是"测试覆盖哪些版本"的判断，**与代码改动同走 PR review**（ADR-004 已撤销"发版后必须 re-pin"与"机械 re-pin 可直推 main"两条规则）。

**`seed_load` 的四分返回码**（调用方一律走 `lib/seed.sh` 的 `seed_load_require`，别自己写 switch）。**这不是新的宽松语义，而是把 ADR-003 早已写死的分类落实**——旧代码把"缺件"也返回 1（FAIL），与 ADR-003 的"预先声明的种子缺失 → UNMET"相矛盾：

| 观察到的情形 | 返回码 | case 状态 | 含义 |
|---|---|---|---|
| 事实源与全部对象就位、现算 == pin | 0 | （继续跑） | 输入可用 |
| 事实源缺 `SEED_TAG`/`SEED_DSH_VERSION`、记录格式非法、哈希工具失败 | 2 | **ERROR** | 校验根本没跑成 |
| 对象**在**、但现算 != pin（含 CAS 目录名与内容不符） | 1 | **FAIL** | 验证完成、结论否定 |
| 缺事实源、或缺对象（含旧扁平位置内容不符＝该对象不在） | 3 | **UNMET** | 缺可测输入，**不是**被测对象的结论 |

**UNMET 绝不放行交付**：`UNMET → 退出码 3 → 结论 INCOMPLETE`（`state_verdict` 只在
无 FAIL/ERROR/UNMET 且人工项齐备时才给 READY）。实测矩阵：

```
PASS -> exit 0, verdict READY          FAIL  -> exit 1, verdict REJECTED
UNMET-> exit 3, verdict INCOMPLETE     ERROR -> exit 2, verdict REJECTED
```

即 **只有 PASS 能给 READY**；UNMET 阻断资格（只是归类诚实地表明"没有结论"而非"结论是否定"）。

## tools/ 维护者工具

整目录白名单：**可复用的本地工具一律放这里**，放进来即自动纳管，不必逐文件改 `.gitignore`；一次性脚本不留存、不散落在 `.test-install/` 根目录。

| 工具 | 用途 |
|---|---|
| `tb.sh` | 生成 `Tested-by:` trailer（见「合并留痕」） |
| `pr-merge.sh` | 带 trailer 合并 PR（默认 dry-run，`--yes` 才执行；依赖 `gh`） |
| `fetch-candidate.sh` | 按**精确 run id** 取回并核验分支候选产物，打印 `DSH_CANDIDATE_ARTIFACT=<目录>` |
| `build-patchset.sh` | 符号链接到 `build/build-patchset.sh`（补丁集打包器的唯一实现） |
| `intent-token-probe.sh` | 真机探针：`?token=` URL 经 Android intent 链是否被截断、同端口二次打开是否复用标签 |
| `browser-probe.sh` | 一次性探针：把 `dsh → xdg-open → $BROWSER → opener → am` 逐段切开定位断点 |
| `smoke-runner.sh` | 冒烟：`run.sh` 的编排（选择/前置/执行/补记/聚合/报告） |
| `smoke-sandbox.sh` | 冒烟：隔离与收据（白名单、线上守卫、**内容身份**、两套基底） |
| `smoke-inputs.sh` | 冒烟：具名输入的解析/冻结/失败分类（dist-tag→精确版本+SRI） |
| `smoke-probes.sh` | 冒烟：行为探针的**触发派生**与失败语义（写死 marker 会静默降级） |
| `smoke-patchset.sh` | 冒烟：产物内注册表的文本解析与 wrapper 钩子能力派生 |
| `smoke-fetch-candidate.sh` | 冒烟：候选产物取证/绑定逻辑（用**假 `gh`**，覆盖每条拒绝路径） |

**六个 `smoke-*.sh` 是"测试体系自己的测试"**，全部进 CI 的 `static`。改 `lib/**`、`run.sh`、`serve.sh`、`cases/**`、`tools/**` 时它们就是护栏——开发中抓到过 20+ 个真实缺陷。

## shebang 与"怎么调用脚本"

设备（Termux/Android）与 CI（ubuntu runner）**没有共同的绝对解释器路径**，所以规则按**"谁去执行它"**分，不按扩展名分：

| 类别 | 规则 |
|---|---|
| **被内核直接执行 / 经 PATH 调用**的生成物 | 必须是**目标主机上存在的字面绝对路径**（已符合：`dsh` wrapper、`$BROWSER` opener、沙箱 `grun`、生成类 case 的 `#!${BASH:-<绝对路径>}`） |
| **受跟踪脚本**（`run.sh`/`serve.sh`/`tools/*`/`cases/*`/`lib/*`/`scripts/*`/`build/*`） | **契约是显式调用**：`bash <file>`、`exec bash <file>` 或 `source`。**shebang 不承担可移植性** |

**三条实测事实**（别凭直觉改）：① 内核解析 `#!` 时**只认字面绝对路径**——不走 `PATH`，**也不做变量展开**，所以 `#!$PREFIX/bin/env bash` 和 `#!/usr/bin/env bash` 一样会失败；② 设备上 **`/usr/bin/env` 这条路径不存在**（`env` 在 `$PREFIX/bin/env`），所以 `#!/usr/bin/env bash` **只在被直接 exec 时**才现形，`bash -n`、shellcheck 与静态检查都看不见；③ 失败退出码**不是契约**。

**因此不做**：(a) 全仓机械替换 shebang（会在 CI 与设备之间制造不存在的差异，并让"统一成一个绝对路径"这种**错误**修法看起来可行）；(b) 加"按文件名/扩展名/执行位猜谁会被直接执行"的静态护栏——这些信号**都证明不了"永不直接 exec"**，一个调用点排除不了另一个调用者，而假阴性（真机断裂却能过必需的 CI）比假阳性更糟。**给生成物的规则**：在**执行主机上**生成时解析解释器（两种既有写法：`#!${BASH:-<绝对路径>}` 与 `printf '#!%s\n' "$(command -v bash)"`），**不要把生成脚本跨主机复制**；为 Termux 构建的产物必须保留 Termux 的解释器，即使构建发生在 Ubuntu 上。**"为什么"见 ADR-012。**

## 工作区补丁集注入

把**工作区**补丁集打到一棵**已随 tarball 打过补丁**的 work 树上（`lib/patchset.sh` 的 `patchset_overlay_workspace_patches`；消费者是 `dry-run/pinned-rebase`、`dry-run/candidate-artifact` 与 CI 的 `patch-matrix.sh`。**serve.sh 已不再 overlay**）。两步缺一不可：

1. **先用该树自带的 `patches/` 逐条回退**。那份 patches/ 与这棵树的来历同一，正是"造出树上 post-image 的那一版"；而 `dsh_apply_patch` 的幂等**只认手上这份补丁文件的字节**——被改写过的补丁（重锚/加宽/因漂移重生成）直接 apply 会既退不掉旧 post-image 又打不上，还把结论报成上游"版本漂移"（2026-09-08 真机撞到：逐版本 pristine 矩阵全绿，serve.sh 拒绝启动）。
2. **再走生产入口 `dsh_apply_patch_set`**，与 install/update/发版构建同一判定（含 precondition 跳过与 marker 验证），不在这里另立一套标准。

回退不动的条目跳过，让第 2 步给出它自己的响亮结论。**`PATCHES_DIR` 必须是绝对路径**：`dsh_apply_patch` 是 `git -C <work_dir> apply <patch>`，相对路径按 work 目录解析，症状是 `can't open patch` 被报成版本漂移。**注意**："overlay 前后树身份必须不同"是**错断言**——工作区补丁集与发布物自带那套一致时（发布后没人改补丁＝常态）这条是**幂等**的，判别器是 marker 齐全 + 行为探针 + boot。

## 沙箱边界（铁律）

- 沙箱期间 `HOME`/`TMPDIR`/`DSH_RUNTIME_DIR`/`DSH_BIN_DIR` 必须指向各沙箱目录内；**严禁**改动/删除/重装本地正在运行的 dsh runtime：`~/.local/opt/dsh-termux-runtime/`、`~/.local/bin/dsh`、`~/.bashrc`、`~/.dsh`；`grun` 用 stub（`exec "$@"`），不得调用真机 grun。
- 每个 case **前后**各做一次**线上全路径签名**比对，变了就把这次运行的结论作废。`~/.dsh` 刻意**不在**守卫里：它是活着的会话状态目录，一直在被写（实测 6 秒签名就变），一个总是红的守卫等于没有守卫（ADR-008）。
- 临时文件一律落**工作区/沙箱内**（本仓库为 `.test-install/sandbox-*/tmp`）。**Termux 下禁访系统 `/tmp`**；`TMPDIR` 由沙箱隔离强制覆盖，不依赖任何系统 tmp——理由从"写不进去"变成"能写也不该写"：这是隔离要求（可复现、可清理、不污染用户环境），不是权限问题。
- 磁盘：`seeds/seed-assets/` ~100MB（内容寻址，同内容只存一份），每个 `sandbox-*/` ~0.5GB；带人工清单的 case 通过后保留的沙箱**是为人类实测保留的**，一晚上跑几次 `verify` 会堆到 GB 级。CAS 对象**不自动回收**：`seed rm` 只删事实源，可能仍被别的种子引用。

## 新增一个 case

四步缺一不可；`run.sh validate`（含 `--strict-executors`）双向断言它们对得上：**登记的 executor 必须存在**，且已登记的 case 脚本必须都在清单里（防单边遗漏）。

1. **登记**：在 [cases/registry.tsv](cases/registry.tsv) 加一行（10 段，格式与逐字段枚举见该文件头部注释）。`changes` 里的 glob **必须真能匹配到文件**——拼错 = 这条 case 从此永不被 diff 选中，而报告上什么都看不出来（`validate` 会报）。用到的 `human` 清单 id 必须有 `cases/checklists/<id>.txt` 正文。
2. **写 executor**：`cases/<id>.sh`。只 source 真正需要的库；开头 `case_begin`，结尾 `case_finish`；断言用 `assert_pass`/`assert_fail`，缺结论用 `case_unmet`，配置或框架故障用 `case_error`——**分类看"是否完成了验证"，不看错误是否来自外部**：资产 hash 与 pin 不符、架构不符、被测脚本非零退出 = FAIL；种子缺失、设备不在、网络不可达 = UNMET。仓库一律用 `$DSH_HARNESS_ROOT` **绝对**引用（cwd 在沙箱内，相对落点会被冒烟抓）；拿到的是**白名单环境**，需要父进程变量必须显式加进 `SANDBOX_PASSTHROUGH`。证据写两处：`evidence-*.txt`（人读）+ `receipt_case_facts`（耐久、只追加；**写不进去就 `case_error`**——必要证据写不进去 = 本次结论不成立）。
3. **跑**：`run.sh check -c <id>` 单跑；通过且带人工项的 case，`verify` 会**保留沙箱**并把 `serve.sh --sandbox <名>` 打印出来（不用自己写）。
4. **加护栏**：真机跑通后，把可复现的那部分逻辑抽进 `tools/smoke-*.sh`（自造 git 仓库 + 假清单 + 假 case，不碰真 registry），再进 CI。

## 合并留痕（Tested-by）

人类实测确认后，把凭据写成 `Tested-by:` trailer 带进合并（或末位）提交——git 历史即永久台账（`git log --grep='^Tested-by:'` 可检索），PR 正文保持干净：

```sh
bash .test-install/tools/tb.sh "full gate + serve.sh checklist"   # 被测树 = 当前分支 tip
bash .test-install/tools/tb.sh "clean checklist" 60944a5          # 显式指定被测树
bash .test-install/tools/tb.sh --review "CI-only, no on-device surface"
```

**范围在前，哈希在后**；`@哈希` 由工具生成，不要手输（工具会拦截塞错位置）。`--review` 只给**没有真机面**的改动（纯 CI / 纯工作流），标签由 `on-device` 变 `review`；**凡是能落到设备上的改动一律用默认 `on-device`**——用 review 蒙混等同于铁律里禁止的"拿自动测试冒充实测"。纯文档类**根本不需要 trailer**。**合并动作**用 `bash .test-install/tools/pr-merge.sh <PR号> "<范围>"`（默认 dry-run，`--yes` 才执行；它内部调 `tb.sh`）——**手拼 trailer 视为流程错误**。格式规范与治理边界见 AGENTS.md §6.3。

## 已知约束

- **`--json` 需要 `python3`**（设备与 CI 都有；文本报告不依赖它）。stdout 只给报告、stderr 给过程，所以 `--json` 可以直接管道给解析器。
- **落盘布局**（都在 ignore 的 `state/` 下）：`<run-id>/`（results / report / build-receipt / guard / input-npm-target / input-release）、`receipts/`（内容寻址 build 收据 + 只追加的 `test.tsv` 与 `case-facts.tsv`，`clean` 保留）、`smoke/`。
- **本地源码不冻结**（ADR-015 已删 `source_digest` 与其在 serve 的硬闸门）：改文档不再触发"源漂移"。真正需要逐件核验的是**外部字节**——种子 sha256、`download-path` 的"下载字节 == pin"、npm 的 SRI 闭环。
- **踩过的坑不在这里**：那张按主题列出的"勿回退"清单（每条对应一个真踩过的失效，例如 `for x in $csv` 会做路径展开、函数头注释会吞掉下一行的 `local`、`cat > file` 会跟随 symlink 写进载荷内部）在 [STATUS.md](STATUS.md) 的「勿回退」一节——**改测试体系前先读它**，本文不复制。
