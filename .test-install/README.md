# .test-install/ — 本地沙箱测试体系

> 本目录是 dsh-termux 的质量基础设施:沙箱自动层(五条路线)+ 人类实测层(serve.sh)。
> 协议的**不变量**(铁律、Termux 禁忌、token 纪律、交付门槛)在仓库根 `AGENTS.md`;
> 本文件承接其 §1 的**操作细节**——跑测试、改测试、排障时读这里。
> 改动本目录代码与改动仓库代码同等对待:同 PR、同 review(代码已纳入 git 跟踪,
> 数据/沙箱/审计产物仍被 ignore)。

## 目录

```
.test-install/
├── run.sh                 # 唯一入口: r1|r2|r3|r4|r5|all|serve|baseline|clean
├── baseline.env           # 基线事实源(唯一数据处; 由 run.sh baseline set 写出, 不手编)
├── sandbox-lib.sh         # 公共核心: 隔离导出/唯一 unset 清单/grun stub/断言计数/
│                          #   线上哨兵/shipped 补丁集解析/landlock 行为探针
├── routes/                # 五条路线的驱动+专属断言(共性全在 sandbox-lib.sh)
├── serve.sh               # 人类实测入口: 沙箱内起 dsh web 供浏览器点检
├── README.md              # 本文件
├── release-test/          # [ignore] 基线发布物本体 ~100MB(tarball + install.sh)
└── sandbox-*/ scratch-*/  # [ignore] 各路线沙箱(重跑自动重建)与研发残留
```

## 快速上手

```sh
bash .test-install/run.sh help        # 全部命令一屏带注释
bash .test-install/run.sh all         # 交付门槛 = r1+r2+r4+r5 (--with-r3 追加 r3)
bash .test-install/run.sh r1          # 单跑一条(日常迭代只需这条)
bash .test-install/serve.sh           # 人类实测: 先跑门槛, 再起沙箱 Web (端口 3141)
```

判定标准:**任何断言失败即 FAIL,禁止跳过或「只跑个大概」**;每条路线结束打印
`== [rN] done: N ok ==` 与集中 WARN。

## 五条路线

| 路线 | 命令 | 测什么 | 网络 | 备注 |
|---|---|---|---|---|
| R1 | `r1` | 工作区 `build/install.sh` × 基线 tarball 全安装接线(每次迭代必跑) | 无 | ~12s;期望版本取自 baseline.env |
| R2 | `r2`(`--pinned` 离线测 pin 资产) | **下载当前 latest release** 认证:shipped install.sh + tarball 完好 | 默认需要 | 认证对象=用户将拿到的最新产物;下载物进沙箱 dl/,不碰 release-test/;1.2.1 起条件断言 tarball 顶层 VERSION |
| R3 | `r3` | 工作区 `00-setup` 流水线 01→02(npm)→03(补丁)→自含复制段→04 | npm + nodejs.org | **冷装 20min+ 属正常**;前置预检真机 glibc 三件套 |
| R4 | `r4` | 种子旧 runtime → **工作区** `update-dsh.sh -t <tag> -y` 更新机制 | npm registry | `DSH_UPDATE_TAG=<tag>` 换目标;断言 wrapper 钩子指向 runtime 内置更新器 |
| R5 | `r5` | 同 R4 但种子=**latest 下载的** runtime、执行其**内置**更新器+补丁(Option A 真实路径);tarball 携带 VERSION 时加跑 **--self 自更新链路**(优先 ~40KB 补丁包资产、无资产回退完整 tarball),旧 release note 跳过;普通更新段的自动补丁集刷新对种子(=latest)天然判定一致 | npm registry | 钩子期望值按 shipped common.sh 能力派生 |

R4 与 R5 共用 `sandbox-update/` 目录,**不可并行**。

### 断言分级

- **行为级**(证明"行为对"):node readelf+直连运行、wrapper 真实 exec 出版本、
  opener 退出码、symlink 执行、线上哨兵(sha256+运行)、landlock tmpdir 探针
  (真实 import 被测树 dsh-sandbox-local,断言 workspace-write 授权表含
  `os.tmpdir()` 且 read-only 仍只授 `/dev/null`)。
- **marker 级**(证明"文件变过"):补丁标记 `grep`(三段式 DSH_PATCH_SET 派生)、
  wrapper 钩子存在性。两个 hard-link 补丁目前是 marker 级(fs-local 存在
  `internals.linkFile` 注入缝,是后续行为探针的候选;session-persistence-jsonl
  无注入缝,维持 marker 级,理由见本地审计)。
- **期望值派生**:版本←baseline.env;补丁清单/marker←DSH_PATCH_SET(工作区或
  shipped 副本,两段式旧条目回退 platformLinkDenied);wrapper 钩子←生成器能力
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
> 都不得指向线上 runtime/`~/.dsh`/`~/.bashrc`——沙箱里能复现一切待验证行为
> (门槛全绿 + 工作区补丁注入保证了这一点);线上升级只作为最后一步,执行的
> 是沙箱里已验证过的产物。(教训:曾两次把实测清单写成直改线上,被人肉纠正。)

```sh
bash .test-install/serve.sh             # 门槛(r1)全绿才起服务, 端口 3141
bash .test-install/serve.sh 3099        # 换端口
PORT=3099 bash .test-install/serve.sh   # 环境变量方式
WITH_CREDS=1 bash .test-install/serve.sh # 复制线上 ~/.dsh 凭据进沙箱(实测聊天)
NO_OPEN=1 bash .test-install/serve.sh   # 不自动开浏览器(agent 冒烟)
REUSE=1 bash .test-install/serve.sh     # 复用沙箱(仅限网页行为迭代, 跳过门槛)
```

- **工作区补丁集注入**:门槛通过后,serve.sh 把工作区 `DSH_PATCH_SET` 打到
  沙箱 work 树(marker 验证 + landlock 探针,失败拒绝启动)——基线 tarball 的
  补丁集永远滞后于工作区,不打这步新补丁无从实测(历史教训:曾因此把实测
  步骤错误指向线上 runtime,违反沙箱边界);
- 隔离:HOME/TMPDIR/TMP/XDG_*/DSH_* 全指沙箱内,`--host 127.0.0.1` 显式;
- 点检清单(启动时打印):页面标题→建会话发消息→写/读文件落沙箱 ws/→
  **3b) bash 里 `mktemp -d` + `echo x > $TMPDIR/t`(landlock 补丁验收点)**→
  浏览器交接→线上不受影响→Ctrl-C;
- 凭据:沙箱默认无 API Key(发消息会提示,属预期);实测聊天需 WITH_CREDS=1
  或沙箱 UI 手填,未配时该项标「未实测」;
- 沙箱保留在 sandbox-run/,磁盘紧张 `run.sh clean`(只删 sandbox-*,保留
  基线/路线代码/baseline.env;非白名单残留仅提示)。

## 沙箱边界(铁律)

- 沙箱期间 HOME/TMPDIR/DSH_RUNTIME_DIR/DSH_BIN_DIR 必须指向各沙箱目录内;
- **严禁**改动/删除/重装线上:`~/.local/opt/dsh-termux-runtime/`、
  `~/.local/bin/dsh`、`~/.bashrc`、`~/.dsh`;
- `grun` 用 stub(`exec "$@"`),不得调用真机 grun;
- 磁盘:release-test/ ~100MB,每个 sandbox-*/ ~0.5GB;`run.sh clean` 清理,
  重跑自动重建。

## 已知约束与历史教训(改测试前必读)

- `r4/r5 共用 sandbox-update/` 的串行约束目前只有文档约束,无锁——**不要并行跑**;
- `fetch_release_assets` 绝不用 `wget -c`(代理续传拼出「新包+旧尾」的事故);
- `sandbox_init` 的 rm -rf 锚定 `BASH_SOURCE` 而非 CWD(防绕过 run.sh 时删错目录);
- `env_sanitize` 是唯一 unset 清单(历史上窄清单漂移过一次);
- serve.sh `REUSE=1` 跳过门槛仅限网页行为迭代——安装链路改动禁止跳过;
- landlock 探针的触发 marker 目前是沙箱 lib 内的固定串(marker 改名时探针会
  note 跳过而非 FAIL——已知欠账,改进方向:从注册表派生触发条件)。

## 新增一条路线

在 `routes/` 写驱动+专属断言(source sandbox-lib.sh)、在 `run.sh` 登记映射与
all 列表、在本文件路线表加一行、AGENTS.md 的 §1 摘要表(如涉及)同步。
