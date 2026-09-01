# .test-install/ — 本地沙箱测试体系

> 本目录是 dsh-termux 的质量基础设施:沙箱自动层(六条路线)+ 人类实测层(serve.sh)。
> 协议的**不变量**(铁律、Termux 禁忌、token 纪律、交付门槛)在仓库根 `AGENTS.md`;
> 本文件承接其 §1 的**操作细节**——跑测试、改测试、排障时读这里。
> 改动本目录代码与改动仓库代码同等对待:同 PR、同 review(代码已纳入 git 跟踪,
> 数据/沙箱/审计产物仍被 ignore)。

## 目录

```
.test-install/
├── run.sh                 # 唯一入口: r1|r2|r3|r4|r5|r6|all|serve|baseline|clean
├── baseline.env           # 基线事实源(唯一数据处; 由 run.sh baseline set 写出, 不手编)
├── sandbox-lib.sh         # 公共核心: 隔离导出/唯一 unset 清单/grun stub/断言计数/
│                          #   运行中 runtime 哨兵/shipped 补丁集解析/行为探针(landlock+fs-local)
├── routes/                # 六条路线的驱动+专属断言(共性全在 sandbox-lib.sh)
├── serve.sh               # 人类实测入口: 沙箱内起 dsh web 供浏览器点检
├── README.md              # 本文件
├── release-test/          # [ignore] 基线发布物本体 ~100MB(tarball + install.sh)
└── sandbox-*/ scratch-*/  # [ignore] 各路线沙箱(重跑自动重建)与研发残留
```

## 快速上手

```sh
bash .test-install/run.sh help        # 全部命令一屏带注释
bash .test-install/run.sh all         # 交付门槛 = r1+r2+r4+r5+r6 (--with-r3 追加 r3)
bash .test-install/run.sh r1          # 单跑一条(日常迭代只需这条)
bash .test-install/serve.sh           # 人类实测: 先跑门槛, 再起沙箱 Web (端口 3141)
```

判定标准:**任何断言失败即 FAIL,禁止跳过或「只跑个大概」**;每条路线结束打印
`== [rN] done: N ok ==` 与集中 WARN。

## 合并留痕(Tested-by)

人类实测确认后,在合并/末位提交信息尾部追加一行 trailer,git 历史即实测台账
(`git log --grep='^Tested-by:'` 可检索;格式规范见 AGENTS.md §6.3)。`范围`
= 一句本次人类实测覆盖面的描述,原样进入 trailer:

```sh
bash .test-install/tb.sh "r6 + full gate"          # 被测树=当前分支 tip
bash .test-install/tb.sh "clean checklist" 60944a5 # 显式指定被测树
bash .test-install/tb.sh --review "CI-only, no on-device surface"  # 无真机面
```

- 参数顺序:**范围在前,哈希在后**;输出里的 `@哈希` 是工具生成的,不要手输;
- 名字取 `git config user.name`,时刻取本地时间含时区,哈希取 tree-ish 短哈希;
- `--review` 只给**没有真机面**的改动用(纯 CI / 纯工作流),标签由 `on-device`
  变 `review`,凭据是人类审阅 + CI 绿;凡是能落到设备上的改动一律用默认的
  `on-device`——用 review 蒙混过去等同于 §0 里禁止的「拿自动测试冒充实测」;
- 纯文档类合并无实测项,无需 trailer;
- 输出仅一行到 stdout,粘进合并对话框的提交信息框即可。

## 六条路线

| 路线 | 命令 | 测什么 | 网络 | 备注 |
|---|---|---|---|---|
| R1 | `r1` | 工作区 `build/install.sh` × 基线 tarball 全安装接线(每次迭代必跑);1b 覆盖重装回归(种入旧 npm 树残留→重装→断言清空+npm 模块链可加载) | 无 | ~25s(两次解包);期望版本取自 baseline.env |
| R2 | `r2`(`--pinned` 离线测 pin 资产) | **下载当前 latest release** 认证:shipped install.sh + tarball 完好 | 默认需要 | 认证对象=用户将拿到的最新产物;下载物进沙箱 dl/,不碰 release-test/;1.2.1 起条件断言 tarball 顶层 VERSION |
| R3 | `r3` | 工作区 `00-setup` 流水线 01→02(npm)→03(补丁)→自含复制段→04 | npm + nodejs.org | **冷装 20min+ 属正常**;前置预检真机 glibc 三件套 |
| R4 | `r4` | 种子旧 runtime → **工作区** `update-dsh.sh -t <tag> -y` 更新机制 | npm registry | `DSH_UPDATE_TAG=<tag>` 换目标;断言 wrapper 钩子指向 runtime 内置更新器 |
| R5 | `r5` | 同 R4 但种子=**latest 下载的** runtime、执行其**内置**更新器+补丁(Option A 真实路径);tarball 携带 VERSION 时加跑 **--self 自更新链路**(优先 ~40KB 补丁包资产、无资产回退完整 tarball),旧 release note 跳过;普通更新段的自动补丁集刷新对种子(=latest)天然判定一致 | npm registry | 钩子期望值按 shipped common.sh 能力派生 |
| R6 | `r6` | **工作区更新器的 self_update 全链路**(r4 种子与 latest 一致时该路径天然不触发、r5 1b 执行的又是旧 shipped 更新器——新代码此处零覆盖,固化自一次性演练):Part A 显式 `--self -y`(播种假旧 VERSION+弄脏补丁 → 断言「旧→新项目版本显示」/VERSION 替换/npm 完成,re-exec 的是下载到的 shipped 更新器=用户真实路径);Part B 白盒模拟 re-exec 后哨兵(env 即 exec 会带过去的):答 n 中止且「补丁未应用」NOTE 仅当补丁集真变化(DSH_PATCHES_CHANGED 区分);Part C `-y`+哨兵 → 全链路成功、明示在、停止提示被抑制 | GitHub + npm registry | 期望值按 latest tag 尾段动态派生(不硬编码项目版本);Part B/C 以 DSH_SELF_DONE=1 关自动判定,防基线 pin 落后 latest 时被真刷新劫走模拟 |

R4 与 R5 共用 `sandbox-update/` 目录,**不可并行**;R6 用独立 `sandbox-self/`,
可与其并行但建议顺序跑(共享 npm/GitHub 带宽)。

### 断言分级

- **行为级**(证明"行为对"):node readelf+直连运行、wrapper 真实 exec 出版本、
  opener 退出码、symlink 执行、运行中 runtime 哨兵(inode/mtime/size/sha256 四元组快照)、
  landlock tmpdir 探针(真实 import 被测树 dsh-sandbox-local,断言
  workspace-write 授权表含 `os.tmpdir()` 且 read-only 仍只授 `/dev/null`)、
  fs-local link→rename 探针(经公共 API `LocalFileSystem.internals` 注入
  linkFile 拒绝,断言 rename 回退落盘;负控制 EFOO 必须原样抛出,防注入缝
  失效后假绿)。
- **marker 级**(证明"文件变过"):补丁标记 `grep`(DSH_PATCH_SET 派生;四段式
  条件条目在不适用的 dsh 版本上记 note 跳过,不作要求)、
  wrapper 钩子存在性。hard-link 补丁的验证不对称:fs-local 已行为级;
  session-persistence-jsonl 无注入缝,维持 marker 级(理由见本地审计)。
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

> **原则:人类实测必须经 serve.sh 的沙箱环境。** agent 交付的任何实测步骤
> 都不得指向本地正在运行的 dsh runtime/`~/.dsh`/`~/.bashrc`——沙箱里能复现一切待验证行为
> (门槛全绿 + 工作区补丁注入保证了这一点);对本地正在运行的 dsh runtime 的升级只作为最后一步,执行的
> 是沙箱里已验证过的产物。(教训:曾两次把实测清单写成直改本地正在运行的安装,被人肉纠正。)

```sh
bash .test-install/serve.sh             # 门槛(r1)全绿才起服务, 端口 3141
bash .test-install/serve.sh 3099        # 换端口
PORT=3099 bash .test-install/serve.sh   # 环境变量方式
WITH_CREDS=1 bash .test-install/serve.sh # 复制本地正在运行的 dsh runtime 的 ~/.dsh 凭据进沙箱(实测聊天)
NO_OPEN=1 bash .test-install/serve.sh   # 不自动开浏览器(agent 冒烟)
REUSE=1 bash .test-install/serve.sh     # 复用沙箱(仅限网页行为迭代, 跳过门槛)
```

- **工作区补丁集注入**:门槛通过后,serve.sh 把工作区 `DSH_PATCH_SET` 打到
  沙箱 work 树(marker 验证 + landlock/fs-local 双行为探针,失败拒绝启动)——
  基线 tarball 的补丁集永远滞后于工作区,不打这步新补丁无从实测(历史教训:
  曾因此把实测步骤错误指向本地正在运行的 runtime,违反沙箱边界);
- 隔离:HOME/TMPDIR/TMP/XDG_*/DSH_* 全指沙箱内,`--host 127.0.0.1` 显式;
- 点检清单(启动时打印):页面标题→建会话发消息→写/读文件落沙箱 ws/→
  **3b) bash 里 `mktemp -d` + `echo x > $TMPDIR/t`(landlock 补丁验收点)**→
  浏览器交接→本地正在运行的 dsh runtime 不受影响→Ctrl-C;
- 凭据:沙箱默认无 API Key(发消息会提示,属预期);实测聊天需 WITH_CREDS=1
  或沙箱 UI 手填,未配时该项标「未实测」;
- 沙箱保留在 sandbox-run/,磁盘紧张 `run.sh clean`(只删 sandbox-*,保留
  基线/路线代码/baseline.env/留档目录/锁文件;非白名单残留仅提示)。

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
- serve.sh `REUSE=1` 跳过门槛仅限网页行为迭代——安装链路改动禁止跳过;
- ~~行为探针的触发 marker 硬编码~~ 已修(PR #11):两个探针的触发 marker 均由
  调用方从注册表派生,marker 改名自动跟随;跳过可见性分级(note=旧产物合理
  跳过;warn_record=注册表声明了但 lib 缺 marker 的真降级信号,进 summary)。

## 新增一条路线

在 `routes/` 写驱动+专属断言(source sandbox-lib.sh)、在 `run.sh` 登记映射与
all 列表、在本文件路线表加一行、AGENTS.md 的 §1 摘要表(如涉及)同步。
