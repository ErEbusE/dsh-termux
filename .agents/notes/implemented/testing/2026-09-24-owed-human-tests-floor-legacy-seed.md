# Agent Note: 补齐三类欠账的真机实测（serve-floor / serve-legacy / 种子路径）

Status: implemented

## Problem

PR #38 的自动层早已全绿，但 `STATUS.md` 明确留着三处「待人类实测」：

- 第 49/449 行：`release-install/legacy-tarball` 的人工清单 `serve-legacy`（11d）从未被人类跑过；
- 第 63 行：ADR-014 的**种子存储修复**（内容寻址、失败安全发布、记录形状校验）从未被人类看过；
- 11c 的 `update/support-floor`（人工清单 `serve-floor`）同样从未被人类实测。

维护者本轮选定「先补欠账，再合并」。这直接决定合并提交里 `Tested-by` 能诚实地写多大范围——
本 PR 相对 main 有 87 个文件（含 `scripts/` 安装/更新脚本与 ADR-014 的种子修复），
而此前人类只实测过 `serve-patch` 那一棵树。若把局部说成整体，就是拿自动测试冒充实测。

## Decision

为欠账逐个准备**可照抄的实测对象**，并写一份覆盖三者的任务检查清单：

- `sandbox-update-support-floor`：`run.sh check -c update/support-floor` 装出（真机 47 断言全过），
  验「低于下限被拒绝、且没有副作用」，不是更新本身；
- `sandbox-release-install-legacy-tarball`：`check -c release-install/legacy-tarball --release-tag
  pre-dsh-0.1.3-alpha.2-g82a5fd6-1.2.8` 装出（真机 22 断言全过，含 `fs-ext` 可加载），
  验那份旧产物能装能起——**不**按当前版本标准要求它；
- 种子路径：复用一次性 harness `.tmp-debug/seed-path-review.sh`（`--mode isolated` 承破坏性用例、
  `--mode real` 验真实库语义），跑完断言「清理后源摘要恢复到基线」。

任务检查清单按机制写进 `.test-install/checklists/2026-09-24-owed-tests-floor-legacy-seed.checklist.md`，
`serve.sh` 自动选它（文件名日期最新），并把副本放进沙箱 `home/CHECKLIST.md`。

## Alternatives considered

- **直接按现状合并、`Tested-by` 写「serve.sh + 沙箱启动器」**：否决。范围虽诚实，但 PR 里
  种子修复、install/update 脚本、5 份人工清单都会在没有人类证据的情况下进 main，
  与 STATUS「在人类看过它之前不合并」直接冲突。
- **只写一句含糊的「全部通过」**：否决。这是 AGENTS §0 明令禁止的「拿局部说成整体」。
- **为每个欠账单独开 PR**：否决。欠账属于同一个测试体系重构，不该为了缩小本次合并而拆散；
  逐个清单在**同一轮**里跑完即可。

## Consequences

- 合并前需要维护者花三段真机时间（两个 `serve.sh` + 一段种子命令），换来的是 `Tested-by`
  能写到「这三类欠账 + serve-patch」而不虚报。
- 两个新沙箱各约 700MB，共约 1.4GB 临时占用，测完由 `run.sh clean` 回收（唯一删除者）。
- `.tmp-debug/seed-path-review.sh` 是一次性 harness，**不入库**（`.tmp-debug/` 被 ignore）；
  它沉淀的判定已由 `smoke-runner.sh` 场景 8 长期覆盖。
- 本清单明确排除 `serve-update` / `serve-install` / `serve-chat` 与候选产物真机安装——
  那些仍是欠账，不在本轮范围。
