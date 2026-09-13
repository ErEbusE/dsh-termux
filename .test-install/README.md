# .test-install/ — 本地沙箱测试体系与维护者工具

> 本目录是 dsh-termux 的质量基础设施:沙箱自动层(六条路线)+ 人类实测层(serve.sh)
> + 维护者工具层(tools/)。
> 协议的**不变量**(铁律、Termux 禁忌、token 纪律、交付门槛)在仓库根 `AGENTS.md`;
> 本文件承接其 §1 的**操作细节**——跑测试、改测试、排障时读这里。
> 改动本目录代码与改动仓库代码同等对待:同 PR、同 review(代码已纳入 git 跟踪,
> 数据/沙箱/审计产物仍被 ignore)。

## 目录

```
.test-install/
├── run.sh                 # 唯一入口: list|validate|check|verify|full|finalize|seed|clean
├── serve.sh               # 人类实测入口: 只启动**冻结对象**(--list / --round / --sandbox)
├── lib/                   # 内核: state(协议) registry(清单) seed sandbox(隔离) receipt inputs frozen(冻结对象)
├── cases/                 # case 清单(registry.tsv) + executor + checklists/(人工清单正文)
├── tools/                 # 维护者工具(整目录纳管): tb.sh / pr-merge.sh / smoke-*.sh
├── README.md              # 本文件
├── state/                 # [ignore] 运行留档; receipts/ rounds/ frozen/ 是**证据**, clean 保留
├── seeds/                 # [ignore] 种子事实源与发布物资产
└── sandbox-*/             # [ignore] 各 case 的沙箱; 冻结对象在这里被保留下来供人类实测
```

> ⚠️ 本目录正在从"六条路线"迁移到上面的结构：`routes/`、`sandbox-lib.sh`、
> `baseline.env` 还在盘上但在新入口里**不可达**，只作逐条移植的参照物。
> 接续工作前先读 `.test-install/DECISIONS.md` 的「当前状态（RESUME HERE）」。

## 快速上手

```sh
bash .test-install/run.sh help                 # 全部命令一屏带注释
bash .test-install/run.sh list                 # case 清单(唯一事实源 registry.tsv)
bash .test-install/run.sh check -c <case-id>   # 快集: 点选单跑(不授予交付资格)
bash .test-install/run.sh verify               # 交付裁决: 开一个轮次, 并冻结人类要实测的对象
bash .test-install/serve.sh --list             # 看有哪些冻结对象与轮次
bash .test-install/serve.sh --round <轮次id>   # 起那个人类要实测的对象(端口 3141)
```

判定标准:**任何断言失败即 FAIL,禁止跳过或「只跑个大概」**。

## 合并留痕(Tested-by)

人类实测确认后,在合并/末位提交信息尾部追加一行 trailer,git 历史即实测台账
(`git log --grep='^Tested-by:'` 可检索;格式规范见 AGENTS.md §6.3)。`范围`
= 一句本次人类实测覆盖面的描述,原样进入 trailer:

```sh
bash .test-install/tools/tb.sh "r6 + full gate"          # 被测树=当前分支 tip
bash .test-install/tools/tb.sh "clean checklist" 60944a5 # 显式指定被测树
bash .test-install/tools/tb.sh --review "CI-only, no on-device surface"  # 无真机面
```

- 参数顺序:**范围在前,哈希在后**;输出里的 `@哈希` 是工具生成的,不要手输;
- 名字取 `git config user.name`,时刻取本地时间含时区,哈希取 tree-ish 短哈希;
- `--review` 只给**没有真机面**的改动用(纯 CI / 纯工作流),标签由 `on-device`
  变 `review`,凭据是人类审阅 + CI 绿;凡是能落到设备上的改动一律用默认的
  `on-device`——用 review 蒙混过去等同于 §0 里禁止的「拿自动测试冒充实测」;
- 纯文档类合并无实测项,无需 trailer;
- 输出仅一行到 stdout,粘进合并对话框的提交信息框即可;
- **合并动作**用 `bash .test-install/tools/pr-merge.sh <PR号> "<范围>"`:默认
  dry-run(只打印将写入的合并提交信息),`--yes` 才执行;它内部调 `tb.sh` 生成
  trailer 并写进 merge commit——**手拼 trailer 视为流程错误**。

## tools/ 维护者工具

`.test-install/tools/` 是**整目录白名单**:工具放进来即自动纳入版本管理,不必逐文件
改 `.gitignore`。规则:**可复用的本地工具一律放这里**;一次性脚本不留存、不散落在
`.test-install/` 根目录(先例:`intent-token-probe.sh` 曾以未纳管状态游离,现已移入)。

| 工具 | 用途 |
|---|---|
| `tb.sh` | 生成 `Tested-by:` trailer(见上节) |
| `pr-merge.sh` | 带 trailer 合并 PR(默认 dry-run;依赖 `gh` CLI,见 AGENTS.md §2) |
| `intent-token-probe.sh` | 真机探针:`?token=` URL 经 Android intent 链是否被截断、同端口二次打开是否复用旧标签(`--twice`) |
| `smoke-runner.sh` | **测试体系自己的冒烟**:自造 git 仓库+假清单+假 case,验 `run.sh` 的编排(选择/前置/执行/补记/聚合/报告)。CI 每 PR 必跑 |
| `smoke-sandbox.sh` | 同上思路验**隔离与收据**:白名单环境、线上守卫抓越界、相对落点、沙箱生命周期、build/test 收据、**内容身份**(等长改写/执行位/链接目标都要变)。CI 每 PR 必跑 |
| `smoke-inputs.sh` | 用**本机假 registry** 验具名输入的解析/冻结/失败分类:dist-tag→精确版本+SRI、冻结原子性、未选不联网、缺 integrity→UNMET、非法 selector 拒绝。CI 每 PR 必跑 |
| `browser-probe.sh` | **一次性探针**:把"dsh → xdg-open → $BROWSER → opener → am"这条链逐段切开,人在 Termux 前台每步回答"弹没弹",定位交接断在哪一层(含候选修复的环境对照) |
| `smoke-frozen.sh` | 验**冻结对象/轮次/人工终结**:manifest 三层身份与载荷边界、两类漂移、`serve --check-only` 不改对象、观察台账、同轮终结与轮次隔离、`clean` 保留证据。CI 每 PR 必跑 |
| `smoke-probes.sh` | 验**行为探针的触发条件派生**与失败语义:marker 按补丁目标 rel 从注册表派生(不写死串)、只有条件条目=跳过、同目标多条无条件条目=歧义 FAIL、声明了却缺 marker=FAIL、探针进程失败=FAIL、全跳过=聚合成功(21 项)。探针本体要真 node+真被测树,由真 case 覆盖。CI 每 PR 必跑 |
| `smoke-patchset.sh` | 验**产物内注册表文本解析**(两/三/四段式混排、条件条目跳过、按补丁名反查)与 **wrapper 钩子能力派生**;并反证文本解析与生产 getter 的 marker 逐条一致(20 项)。overlay 本体要真 git 树+真补丁,由 CI 的 `patch-matrix.sh` 覆盖。CI 每 PR 必跑 |

> ⚠️ 下面「六条路线」「基线管理」两节描述的是**被替换中**的旧体系（`rN`、`baseline.env`、
> 旧的 serve 行为），在新入口里都不可达；以 `.test-install/DECISIONS.md` 的「当前状态」为准。
> 完整重写是进度表第 10 项。

## 六条路线

| 路线 | 命令 | 测什么 | 网络 | 备注 |
|---|---|---|---|---|
| R1 | `r1` | 工作区 `build/install.sh` × 基线 tarball 全安装接线(每次迭代必跑);1b 覆盖重装回归(种入旧 npm 树残留→重装→断言清空+npm 模块链可加载) | 无 | ~25s(两次解包);期望版本取自 baseline.env |
| R2 | `r2`(`--pinned` 离线测 pin 资产) | **下载当前 latest release** 认证:shipped install.sh + tarball 完好 | 默认需要 | 认证对象=用户将拿到的最新产物;下载物进沙箱 dl/,不碰 release-test/;1.2.1 起条件断言 tarball 顶层 VERSION |
| R3 | `r3` | 工作区 `00-setup` 流水线 01→02(npm)→03(补丁)→自含复制段→04 | npm + nodejs.org | **冷装 20min+ 属正常**;前置预检真机 glibc 三件套 |
| R4 | `r4` | 种子旧 runtime → **工作区** `update-dsh.sh -t <tag> -y` 更新机制；第 8 步种入假旧 VERSION 强制走**自动刷新分支**（判定落后→下载补丁集资产→re-exec→继续 npm 并完成；marker 从已安装注册表派生） | npm registry + GitHub | `DSH_UPDATE_TAG=<tag>` 换目标;断言 wrapper 钩子指向 runtime 内置更新器 |
| R5 | `r5` | 同 R4 但种子=**latest 下载的** runtime、执行其**内置**更新器+补丁(Option A 真实路径);tarball 携带 VERSION 时加跑 **--self 自更新链路**(优先 ~40KB 补丁包资产、无资产回退完整 tarball),旧 release note 跳过;普通更新段的自动补丁集刷新对种子(=latest)天然判定一致 | npm registry | 钩子期望值按 shipped common.sh 能力派生 |
| R6 | `r6` | **工作区更新器 `--self` 新语义**(刷新机件后直接应用补丁集,不碰 npm):A 本地目录集全链路(断言日志含「先退旧集」+应用+marker+wrapper,且无 npm 查询)/B 机件签名相同→报告已最新并跳过/C `--force` 重打 + `-t/-v` 忽略提示/D 本地 tarball(`build/build-patchset.sh` 现打)消费闭环/E 注册表缺件负例(响亮失败且不改 runtime)/F 哨兵缺失→子 shell 回退应用/G 下载 latest 资产路径/H 白盒哨兵(答 n 中止 NOTE 仅当补丁集真变化) | GitHub(仅 Part G) | 期望值动态派生(工作区 VERSION/脚本、latest tag 尾段、被消费的注册表);A-F/H 离线可跑 |

R4 与 R5 共用 `sandbox-update/` 目录,**不可并行**;R6 用独立 `sandbox-self/`,
可与其并行但建议顺序跑(共享 npm/GitHub 带宽)。

### 断言分级

- **行为级**(证明"行为对"):node readelf+直连运行、wrapper 真实 exec 出版本、
  opener 退出码、symlink 执行、运行中 runtime 哨兵(inode/mtime/size/sha256 四元组快照)、
  landlock tmpdir 探针(真实 import 被测树 dsh-sandbox-local,断言
  workspace-write 授权表含 `os.tmpdir()` 且 read-only 仍只授 `/dev/null`)、
  fs-local link→rename 探针(经公共 API `LocalFileSystem.internals` 注入
  linkFile 拒绝,断言 rename 回退落盘;负控制 EFOO 必须原样抛出,防注入缝
  失效后假绿)、attachment 走根容忍探针(真实 import 被测树
  dsh-attachment-local,向自建的 chmod 311 不可读祖先目录下提交图片——
  `open(dir, O_RDONLY)` 必得 EACCES,天然差分,无需注入:pristine bundle
  整笔失败,补丁后 commit 成功且对象落盘)。
- **marker 级**(证明"文件变过"):补丁标记 `grep`(DSH_PATCH_SET 派生;四段式
  条件条目在不适用的 dsh 版本上记 note 跳过,不作要求)、
  wrapper 钩子存在性。hard-link 补丁的验证不对称:fs-local 已行为级;
  session-persistence-jsonl 无注入缝,维持 marker 级(理由见本地审计);
  attachment 的走根容忍已行为级(天然差分),link→rename 分支无注入缝,
  维持 marker 级(理由同 session-persistence-jsonl,PATCHES.md Patch 7)。
- **期望值派生**:版本←baseline.env;补丁清单/marker←DSH_PATCH_SET(工作区或
  shipped 副本,两段式旧条目回退 platformLinkDenied,四段式条目按前置条件判适用);
  wrapper 钩子←生成器能力
  探测。**没有任何路线硬编码补丁列表或版本号。**

## 基线管理(baseline.env)

基线的 tag / sha256 / 内置 dsh 版本只存在于此一处,`set` 下载资产→现算哈希→
原子写入(`latest` 自动解析为实际 tag):

```sh
bash .test-install/run.sh baseline check      # 查看 pin/哈希/与 VERSION 漂移
bash .test-install/run.sh baseline set latest # 发版后 re-pin
```

- 哈希一律现算,绝不手抄;
- 基线一致性检查:r1/r2-pinned/r3/r4 启动时比对 pin 与仓库 VERSION,不一致
  **WARN 不阻塞**(结论只对「当前 VERSION 的安装脚本」有效)——发版后必须
  回来 `baseline set <新tag>`,WARN 会集中出现在 summary 无法无视;
- `baseline.env` 已入 git:机器无关(公开 release 资产的哈希任何人可复算),
  换机/协作即用;改 pin 只走 `baseline set`,不手编;
- re-pin 是纯派生数据(工具写出/哈希现算/无编辑内容,pin 内容由发布动作
  本身批准):r2+r5 对新 release 全绿后**直推 main,无需 PR**(仅限
  baseline.env 本身;`.test-install` 其余改动仍走 PR——见 AGENTS.md §1)。

## serve.sh(人类实测入口)

> **原则:人类实测必须经 serve.sh 的沙箱环境。** agent 交付的任何实测步骤都不得指向
> 本地正在运行的 dsh runtime/`~/.dsh`/`~/.bashrc`;对本地那个 runtime 的升级只作为
> 最后一步,执行的是沙箱里已验证过的产物。(教训:曾两次把实测清单写成直改本地正在运行的
> 安装,被人肉纠正。)

**serve 只启动"冻结对象",自己不装、不修、不覆盖任何东西。** 冻结对象 = 某条 case 在
沙箱里装出来、被断言过、并写下了身份记录(`state/frozen/frozen-<id>.tsv`)的那棵树。
旧版 serve 在认证完发布物之后**无条件**把工作区补丁 overlay 上去,于是人实测的对象已经
不是被断言的那一个——那是实查更正 C3,现在从结构上不存在了。

用法唯一事实源是 `bash .test-install/serve.sh -h`;下面的流程才是重点:

```sh
# 1) 开一个轮次: 按改动范围算出必需 case, 跑它们, 并为带人工项的 case 留下冻结对象
bash .test-install/run.sh verify
#    报告末尾会给出轮次 id 与下一步命令; 结论此时是 INCOMPLETE(人工项未终结)

# 2) 看有哪些对象
bash .test-install/serve.sh --list

# 3) 起其中一棵, 在浏览器里照打印出来的清单逐项实测
bash .test-install/serve.sh --round <轮次id>            # 只有一个对象时
bash .test-install/serve.sh --round <轮次id> --object <case-id>   # 一轮多个对象时必须指明
bash .test-install/serve.sh --round <轮次id> --with-creds         # 实测聊天(复制本地 ~/.dsh 凭据)

# 4) 人逐项确认后, 用 serve 打印的**对象 id** 终结这一轮
bash .test-install/run.sh finalize <轮次id> --observed <对象id>
```

**开关一律是 `--flag`,写在命令后面。** 旧版 serve.sh 的环境变量写法
(`WITH_CREDS=1` / `REUSE=1` / `NO_OPEN=1` / `TAG=` / `DSH_TARGET=` / `SANDBOX=`) 现在会被
**硬拒绝并给出等价写法**——静默忽略一个用户明确写下的开关比报错糟糕得多(实测踩到:
`WITH_CREDS=1 ... --sandbox <n>` 一路跑完, 沙箱里**没有任何凭据**)。`REUSE` 与
`TAG`/`DSH_TARGET` 没有等价开关: serve 现在只启动已有冻结对象, "复用"就是它的默认
行为; 而"先认证发布物再无条件 overlay"那套已被取消(实查更正 C3)。

- **一个清单 id 可能对应多棵树**:同一人工清单下有多少条 case 就要实测多少个对象,
  在一棵树上点过的通过**不能**自动覆盖另一棵——所以一轮多对象时必须 `--object` 指明;
- **签认绑定对象,不是清单名**:`--observed` 收的是对象记录 id(serve 打印的那个)。
  没有观察记录、只有 start 没有 end、对象不在本轮、对象现在与记录不一致——都会被拒;
- **终结不是新一轮执行**:不重跑 case、不重新解析 `default-target`。独立发起的新
  `verify` 是**新轮次**,不能消费旧轮次的人工签认,即便 build digest 相同;
- **漂移两分**:载荷被改 = 硬拒绝(`--allow-drift` 也绕不过去);只有工作区内容变了才
  可以用 `--allow-drift` 起,而且那次观察仍归属于**冻结记录里的旧主体**,不提供当前
  工作区的资格;
- **可写区在身份之外**:`home/`、`tmp/`、`ws/` 以及 `.cache` 不属于冻结载荷——人类实测
  本身就在写它们,把它们算进身份就是"每次必红的检测";
- **环境政策与 case 刻意不同**:case 用 `env -i` + **白名单**（无人值守、要可复现）;
  serve 用**父环境 − 危险项 + 沙箱钉子**（真实用户就是这么跑的——白名单环境下实测浏览器不弹、
  `~/.profile` 里的 provider key 也进不来）。丢掉的: `LD_*`/`NODE_OPTIONS`/`NODE_PATH`、
  `GH_TOKEN`/`GITHUB_TOKEN`、`SHELL`/`PWD`/`OLDPWD`/`_`、值里含线上 runtime 路径的变量
  （名字打印出来）。**这确实缩小了隔离保证的范围**:钉子 + 路径过滤 + 守卫拦不住"读外部凭据、
  经 `SSH_AUTH_SOCK` 用身份、短暂写后还原"。所以自动层与人工层现在是**互补证据**——
  "该载荷在受控 case 环境下满足自动断言" **且** "在人类这台设备与启动环境下满足人工清单",
  **不是**"自动断言在人类环境里又成立了一遍"。
- **起止两次校验**:serve 启动前与退出后各算一次载荷摘要,任一次不符这段观察就作废;
- **浏览器交接默认不插桩**:dsh 用 `stdio:'ignore'` + detached 起 xdg-open, `open()` 在
  spawn 那一刻就返回成功——所以 serve 默认**不下结论**, 只提醒"以你在浏览器里看到页面为准"。
  定位问题时用诊断开关 `--probe-handoff`(在 `$BROWSER` 前插一层记录用的 shim, 它会**等待**
  opener 返回, 因此不再透明):它打印的是**分层**结论——"没被调用 / 被调用但没返回 / 返回 0 /
  返回 N", 其中"返回 0"只证明**那个进程返回**, 不证明浏览器打开了;URL 与输出里的
  `token=` 一律打码, 全量 URL 只在终端给一次、不落台账;
- **诊断开关**（默认关闭, 打开后的结论**不能**替代默认环境下的人工项签认）:
  `--probe-handoff` 见上;`--strip-android-root` 丢掉 Android 14+ 注入的
  `ANDROID_{ART,I18N,TZDATA}_ROOT` 三个变量(实测在 agent 环境里它们会让 `am` 打不开
  `/dev/binder`, 而人类自己的环境带着它们照样能弹)。**默认保留**——否则就是测试入口替产品
  把问题修好了:载荷摘要没变, 验收的启动条件却被偷偷改过;
- 隔离:HOME/TMPDIR/TMP/XDG_*/DSH_* 全指沙箱内,`--host 127.0.0.1` 显式,线上 wrapper
  目录已从 PATH 摘掉;凭据默认不带(提示缺 API Key 属预期,该项只能标「未实测」)。
  `--with-creds` 做两件事:① 复制本地 `~/.dsh` 的 `.credentials.yaml` + `settings.yaml`;
  ② 把**环境变量型**凭据带进去——配置里 `apiKeyEnv:` 声明的名字,加上通用模式的
  `*_API_KEY`/`*_API_TOKEN`/`*_API_SECRET`(你的 key 可能写在 `~/.profile` 里,
  白名单环境默认会把它丢掉)。**值一律不打印,只打印变量名**;没覆盖到的用
  `--creds-env NAME[,NAME]` 点名。这一条只对 serve 生效——**case 永远拿不到凭据**;
- 点检清单正文在 `cases/checklists/<id>.txt`(数据文件,可摘要);**清单正文的摘要进观察台账**
  (`checklists=<id>=<sha 前 12 位>`),只记 id 记不住"人到底照着哪份清单做的";
- 磁盘:冻结对象是**为人类实测保留的**,一晚上跑几次 verify 会堆到 GB 级;
  `run.sh clean` 清沙箱但**保留** `receipts/`、`rounds/`、`frozen/`(删了就没法终结,
  也没法回溯"当时测的是什么")。

## 沙箱边界(铁律)

- 沙箱期间 HOME/TMPDIR/DSH_RUNTIME_DIR/DSH_BIN_DIR 必须指向各沙箱目录内;
- **严禁**改动/删除/重装本地正在运行的 dsh runtime:`~/.local/opt/dsh-termux-runtime/`、
  `~/.local/bin/dsh`、`~/.bashrc`、`~/.dsh`;
- `grun` 用 stub(`exec "$@"`),不得调用真机 grun;
- 磁盘:release-test/ ~100MB,每个 sandbox-*/ ~0.5GB;`run.sh clean` 清理,
  重跑自动重建。

## 已知约束与历史教训(改测试前必读)

- `r4/r5 共用 sandbox-update/` 的串行约束由 `sandbox_init` 的 flock **强制**:
  并行启动者立即人话报错退出(锁随进程退出自动释放,无陈锁);文档约束升格
  为机制约束;
- `fetch_release_assets` 绝不用 `wget -c`(代理续传拼出「新包+旧尾」的事故);
- `sandbox_init` 的 rm -rf 锚定 `BASH_SOURCE` 而非 CWD(防绕过 run.sh 时删错目录);
- `env_sanitize` 是唯一 unset 清单(历史上窄清单漂移过一次);
- serve.sh 旧开关(`REUSE=1` 等)已全部取消: serve 只启动冻结对象, 不再"跑门槛+overlay";
  旧写法现在被**硬拒绝**(静默忽略过一次, 见 ADR-010 那一节);
- ~~行为探针的触发 marker 硬编码~~ 已修(PR #11):三个探针的触发 marker 均由
  调用方从注册表派生,marker 改名自动跟随;跳过可见性分级(note=旧产物合理
  跳过;warn_record=注册表声明了但 lib 缺 marker 的真降级信号,进 summary)。

## 新增一个 case（第 7c 步要用到的手册）

四步，缺一不可；`registry_validate_unregistered` / `registry_validate_checklists`
（`run.sh validate`）会双向断言它们对得上。

1. **登记**：在 `cases/registry.tsv` 加一行（10 段，格式见该文件头部注释）。
   `changes` 里的 glob 必须真能匹配到文件（拼错 = 这个 case 从此永不被 diff 选中，
   而报告上什么都看不出来——`validate` 会报）；用到的 `human` 清单 id 必须有
   `cases/checklists/<id>.txt` 正文。
2. **写 executor**：`cases/<id>.sh`。约定：
   - 只 source `lib/state.sh`（协议）与真正需要的库；**不** source 旧 `sandbox-lib.sh`；
   - 开头 `case_begin`，结尾 `case_finish`；断言用 `assert_pass/assert_fail`，
     缺结论用 `case_unmet`，配置/框架故障用 `case_error`；
   - 仓库一律用 `$DSH_HARNESS_ROOT` **绝对**引用，cwd 在沙箱内（相对落点会被冒烟抓）；
   - 拿到的是一份**白名单环境**：需要某个父进程变量必须显式加进 `SANDBOX_PASSTHROUGH`；
   - 证据写两处：运行目录里的 `evidence-*.txt`（人读）+ `receipt_case_facts`
     （耐久、只追加；写不进去就 `case_error`——**必要证据写不进去 = 本次结论不成立**）；
   - 通过且带人工项的 case，`verify` 会替它写冻结对象记录并保留沙箱（不用自己写）。
3. **跑**：`run.sh check -c <id>` 单跑；`run.sh check --json` 看结论；
   加 `--freeze` 才会留对象（`check`/`full` 默认通过即删沙箱）。
4. **加护栏**：真机跑通后，把可复现的那部分逻辑抽进 `tools/smoke-*.sh`
   （自造 git 仓库 + 假清单 + 假 case，不碰真 registry），再进 CI。

四个冒烟脚本就是"测试体系自己的测试"：它们能在**没有设备**的情况下验证编排、隔离、
收据、冻结/终结这些判定条件。改 `lib/**`、`run.sh`、`serve.sh`、`cases/**` 时它们就是护栏。
