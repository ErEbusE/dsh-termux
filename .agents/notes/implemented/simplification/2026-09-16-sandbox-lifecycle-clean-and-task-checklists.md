# Agent Note: 沙箱生命周期归 clean、任务检查清单与 Agent Note 入列

Status: implemented

## Problem

上一轮把交付模型的冻结/轮次/签认删掉之后（ADR-015），维护者在实际使用中又指出三件事：

1. **`run.sh` 在偷偷删沙箱**。case 跑完会 `sandbox_teardown`，人还没来得及测，树就没了。
   删除动作应该只有一个入口——`clean`；而且删除前必须让人知道"这是哪个沙箱、什么时候用过"。
2. **检查清单方向错了**。原来的 6 份固定清单（按 case）只覆盖通用回归，**适配新功能时
   根本覆盖不到本次的功能点**——那正是维护者提议"加载检查清单"的初衷。
3. **缺少"意图对齐"的载体**。维护者需要每轮工作后能读懂 agent 做了什么、为什么这么做，
   以便判断是否符合需求、及时纠偏；git commit 记不住"被否决的方案"。

另有一个查出来的事实错误：`serve.sh` 建了一个 `ws/` 目录并把它印成"工作区"、还把进程 cwd
设进去。实测 dsh web 的工作区来自 `$HOME`（会话 header 的 cwd 指向 `home/`），与进程 cwd
无关；而 `ws/` **不在** workspace-write 的写授权表里（授权根是 `home/`）——那个目录既不是
工作区、也写不进去。

## Decision

**1. 沙箱生命周期：创建与删除彻底分开。**
- `run.sh` **只创建**沙箱、只打印路径（"待人类实测"），删掉全部 `sandbox_teardown` 调用与函数；
- `serve.sh` 启动时往 `state/served.tsv` 追加一行「沙箱名 + UTC 时间戳」；
- `run.sh clean` 是**唯一**删除者，默认逐条交互确认：打印「名字 / 上次 serve 启动时间 / 大小」，
  由人决定；没有启动记录的沙箱也列出并标注「可能是失败保留或残留」；非交互（无 tty）默认
  **不删**；`--yes` 非交互全删，`--dry-run` 只列。

**2. 检查清单分两类，任务清单取最新一份。**
- 任务清单 `.test-install/checklists/*.checklist.md`（入库、走 review）：每次改动一份，
  写清本次覆盖的功能点。`serve.sh` 默认取**最新一份**（文件名以 `YYYY-MM-DD` 开头，字典序
  即时间序；`archived/` 不取），打印正文并把副本放进沙箱 `home/CHECKLIST.md`（`home/` 是
  写授权根，沙箱内 agent 能读到）。`--checklist <名字|路径>` 可显式指定（名字自动补后缀）。
- 固定清单 `cases/checklists/<id>.txt` 保留为通用回归。
- 沙箱名 → case 的反查**正向遍历** `sandbox_case_name` 比对，**绝不**把 `sandbox-a-b-c` 用
  `tr - /` 逆向拆——case id 里的 `-` 与 `/` 都压成了 `-`，逆向不可逆（18 条全部对不上）。
- 三种情形分开报：有任务清单 / 只有固定清单（"本次没有任务清单"）/ 两者都没有。

**3. `serve.sh` 的工作区对齐 `home/`。** 删掉 `ws/`（不建、不印、不 `cd`），进程 cwd 设成
`$SB_ROOT/home`——与 `$HOME` 一致，让那批读 `process.cwd()` 作兜底的包也落在唯一可写区内。

**4. 引入 `.agents/notes/`（Agent Note）。** 每次非平凡改动一份，与改动同批提交，简体中文。
生命周期 `proposed/ implemented/ rejected/ archived/`，封闭 6 类 `feature / bug-fix /
simplification / architecture / process / testing`。它与检查清单**不是一回事**：note 记**决策**
（含被否决的方案），checklist 是**给人照做的测试指引**。规则写进 `AGENTS.md`，格式在
`.agents/notes/README.md`。也补了 `!.test-install/checklists/` 的 gitignore 例外。

## Alternatives considered

- **保留 `sandbox_teardown`、只加一个"别删"开关**：否决。默认行为仍会毁掉现场，而开关
  挡不住"忘了加"——删除只留一个入口才没有第二种默认。
- **把任务清单也放进沙箱 home/，只从沙箱读**：否决。`sandbox_prepare` 会 `rm -rf` 整个沙箱
  目录，同名 case 一重跑清单就没了；而且沙箱被 gitignore，清单无法 review。
- **沙箱名用 `tr - /` 反查 case id**：否决。实测 18 条全部解错（`dry-run-pristine-npm` →
  `dry/run/pristine/npm`）。只能在注册表里正向算名字再比对。
- **把检查清单合并进 Agent Note**：否决。维护者明确两者职责不同——note 是决策记录与意图对齐，
  checklist 是"我这次改了什么、请你照这个测"。
- **改 `serve.sh` 的名字（如 `server.sh`）**：否决。它是动词（起进程、等退出），不是常驻服务；
  且约 60 处引用中约 20 处在历史台账（`DECISIONS.md`/`STATUS.md`），改名等于改写历史。

## Consequences

- 沙箱不再凭空消失；代价是磁盘会攒——单沙箱 ~688MB、上限 18 个（沙箱名由 case id 派生，
  同名重跑复用同一个目录），靠 `clean` 回收。这符合维护者"工作结束才清理"的规划。
- `serve.sh` 每次启动会多打印清单正文，输出更长；换来的是人不用另找清单文件。
- 沙箱名 → case 的反查依赖 registry 可读；读不到就跳过清单（只警告），**不影响启动**。
- Agent Note 增加了每轮的工作量，但它换的是"意图可被及早纠正"——本轮的方向性返工正是
  它要防的那类问题。
- `serve.sh` 被再次改动，所以维护者此前那次实测确认**作废**，需按新清单重测一次。
