# 任务检查清单 — 2026-09-24 补齐欠账：serve-floor / serve-legacy / 种子路径

本轮的**任务**不是改代码，而是把三处从未被人类实测过的欠账补上（STATUS 第 49/63/449 行点名的）。
`serve.sh` 启动时会自动读本文件并放进沙箱 `home/CHECKLIST.md`。

三个**独立**对象，逐个测、逐个报告（一个通过不能顶替另一个）。

---

## 一、serve-floor —— `update/support-floor`

对象：一棵**被断言过**的种子 runtime（不是"更新成功后的"那棵）。它验的是"该拒绝的被拒绝、
且没有副作用"，**不是**更新本身。

启动：
```
bash .test-install/serve.sh --sandbox sandbox-update-support-floor --with-creds
```

1) 让沙箱内 agent 在 bash 里跑一次**低于支持下限**的更新目标（路径以沙箱内实际位置为准）：
   `bash scripts/update-dsh.sh -v 0.1.4 -y`
   预期：**非零退出**，且说得清"低于 0.1.5-alpha.1 所以拒绝"。
2) 拒绝文案够不够用：点明版本、下限、理由（0.1.3/0.1.4 需要的原生件本项目已不再构建/分发），
   并给出**可照做**的替代路径（`install.sh -p` 或 `DSH_RELEASE=<tag>`）。
   **不得**承诺一个并不存在的 release —— npm 上有版本 ≠ 本项目有对应发布物。
3) 被拒之后这棵树仍能用：`dsh --version` 与页面/会话行为与实测开始时一致
   （拒绝发生在 npm 改写安装树**之前**，所以这里不该有任何变化）。
4) 另一个入口同样成立：`DSH_VERSION='@deepseek-ai/dsh@0.1.4' bash scripts/02-install-dsh.sh`
   再跑一次，确认同样被拒、同样没改安装树。
5) 边界：全程本地正在运行的 dsh runtime 不受影响（`~/.dsh` 与 `http://127.0.0.1:3080`）。

---

## 二、serve-legacy —— `release-install/legacy-tarball`

对象：**旧 tarball 装出来的**那份 runtime（`pre-dsh-0.1.3-alpha.2-g82a5fd6-1.2.8`）。

启动：
```
bash .test-install/serve.sh --sandbox sandbox-release-install-legacy-tarball --with-creds
```

1) **先确认版本**：应打印 dsh **0.1.3-alpha.2**。不一致则本项直接 FAIL，不必往下做。
   注意：这份产物**没有**后续版本才有的补丁（例如 landlock tmpdir），所以 **不要**用当前版本
   的标准要求它的 `$TMPDIR` 写入、会话保存。
2) **核心**：`dsh web` 起来后页面能打开、标题是 DeepSeek Harness。
   （0.1.3 当年就死在这一步：缺 fs-ext 原生件时 loader 起不来。）
3) 若第 2 项起不来：把**浏览器/终端里原样的报错**贴回来（尤其 `Cannot find module` 一类）。
   **不许**用当前 `scripts/patches` 去 overlay"修好"再测 —— 那样测的就不是这份旧产物了。
4) 边界：全程本地 dsh runtime 不受影响（`~/.dsh` 与 `127.0.0.1:3080`）。

---

## 三、种子路径 —— ADR-014 的存储修复（无沙箱，纯命令）

这验的是**测试体系自己的种子存储**：内容寻址、失败安全的发布、记录形状校验。
它没有可 serve 的产物树，所以用一次性 harness 跑（**不碰真实 `stable` 种子**）。

```
cd /data/data/com.termux/files/home/vibe-coding/dsh-termux
bash .tmp-debug/seed-path-review.sh --mode isolated   # 破坏性那半（深拷贝，安全）
bash .tmp-debug/seed-path-review.sh --mode real       # 真实库那半（约 100MB 下载，仅一次）
```

逐项检查点：
- 两段都要 `pass / fail` 且 **fail=0**；
- real 段要看到 **R4「旧 stable 字节仍在 CAS 且内容相符」**（= 加第二颗种子不覆盖第一颗）；
- real 段要看到 **R5「被 TERM -> 143」＋「中断未残留 staging」＋「中断未留下半条 pin」**；
- 末段要看到 **「清理后源摘要恢复到基线」**（= 预检没留下受跟踪文件）。

---

## 四、通用边界（三个对象都适用）

- 全程**绝不能**触碰本地正在运行的 dsh runtime（`~/.local/opt/dsh-termux-runtime/`、
  `~/.local/bin/dsh`、`~/.bashrc`、`~/.dsh`）；serve 会在起止各做一次守卫。
- 每个对象测完**不要**急着 `clean` —— 保留沙箱，等全部确认完再统一清理。

## 五、本清单不覆盖（明确排除）

- 不覆盖 `serve-update` / `serve-install` / `serve-chat` 三份清单（本轮不做）；
- 不覆盖退役后候选产物的真机安装（另有欠账）；
- 不覆盖升级链路成功路径的细节（`serve-floor` 只验"被拒绝"）。