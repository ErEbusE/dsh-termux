# 任务检查清单 — 2026-09-16 测试体系收窄后续（served 台账 / 任务清单 / clean 交互）

本次改动**不碰 dsh 运行时本身**，改的是测试体系的壳：`serve.sh`（启动器）、
`run.sh clean`（删除者）、沙箱生命周期、任务清单加载。所以下面**大部分是通用回归**，
只有第 1 项是本次的新行为。

## A. 本次新增的行为（重点验）

1) 启动时**自动读到任务清单**：终端里应出现 `---- 任务清单 [<文件名>] ----` 和正文，
   并且沙箱里出现副本。验证：
   - 终端输出里有「---- 任务清单 [」这一行；
   - `ls .test-install/sandbox-<名>/home/CHECKLIST.md` 能列出该副本；
   - 让沙箱内 agent 读 `$HOME/CHECKLIST.md`（或相对路径 `CHECKLIST.md`）能读到同一内容。
   预期：三处内容一致。若终端说「⚠ 本次没有任务清单」，说明清单没放进
   `.test-install/checklists/` —— 那本身就是本项 FAIL。

2) **固定清单仍然打印**：终端里还应有 `---- 固定清单 [serve-*.txt] ----`（本次是
   `serve-patch.txt`），以及一行「（固定清单归属: case dry-run/pristine-npm  human=serve-patch）」。

3) **启动台账**：本次结束后 `cat .test-install/state/served.tsv` 应有一行
   `sandbox-dry-run-pristine-npm<TAB>2026-09-16T…Z`（时间戳是本次启动时刻）。

## B. 通用回归（固定清单里那几条，逐项确认）

4) 页面能打开，标题是 DeepSeek Harness（URL 是一次性握手 `?token=` → 303 → 会话 cookie；
   兑换后地址栏只剩 `127.0.0.1:<端口>`）。若显示 `dsh web authentication required`，
   属补丁 6 (SameSite=Lax) 回归，请报我。

5) 新建会话、发一条消息，agent 能回一轮（需凭据；本次用 `--with-creds`）。

6) 让 agent 写一个文件再读回来，确认落点在沙箱工作区里（`HOME` = `…/sandbox-<名>/home`）。

7) 让 agent 在 bash 里跑 `mktemp -d` 与 `echo x > "$TMPDIR/t" && cat "$TMPDIR/t"`：
   都成功，且落在沙箱 `tmp/`。这是 landlock tmpdir 补丁的验收点。

8) 浏览器交接：启动时自动弹出的那次就是它。serve 默认不插桩、不对「弹没弹」下结论 ——
   弹出且页面正确 = 通过；没弹出 = 不通过，请把带 token 的 URL 手动粘进浏览器并说明。

9) 边界：全程本地正在运行的 dsh runtime 不受影响（`~/.dsh` 与 `http://127.0.0.1:3080`）。

10) Ctrl-C 退出后，本地原来的 `dsh web` 仍能正常打开。

## C. 取值范围（本次不涉及，明确排除）

- 本清单**不**验证 `run.sh clean` 的交互删除（那是 agent 侧自测项，见 smoke 场景 8）；
- **不**验证升级链路、候选产物、旧 tarball（那些各有自己的 case 与清单）。