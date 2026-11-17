# moonmedic 验收自查表(评审版)

> 本页把官方验收要求逐条映射到仓库内的证据位置,并给出 3 条命令的最短复现路径。
> 项目:moonmedic —— MoonBit 实现的 Kubernetes 确定性故障证据引擎 · 2026 MoonBit 黑客松 11 月赛
> 仓库:https://github.com/young9682/moonmedic

## 0. 最短复现路径(3 条命令,离线,无集群/无网络/无 LLM)

```bash
# 1) 安装 MoonBit 工具链后,跑全部单元测试
moon check && moon test          # 51/51 通过

# 2) 离线回放 5 个真实集群采集的故障场景 + golden 断言
./eval/scripts/run-all.sh        # 5/5 PASS

# 3) 单场景查看人类可读诊断报告
moon run cmd/main -- --snapshot eval/fixtures/e01-quota-zero-pods.snapshot.json
```

## 1. 官方验收标准 → 证据映射

| 官方要求 | 仓库内证据 |
|---|---|
| MoonBit 为主要实现语言 | 全仓库 MoonBit 5034 行(占比 96.7%,其余为 169 行评测 shell/python 胶水);native 后端,零 C stub |
| 仓库公开、提交可追踪 | github.com/young9682/moonmedic;main 57+ commits,17 个 PR 全部经 CI 检查后合并,commit 历史自 2026-11-13 起连续可追溯 |
| 能够运行(README/示例/测试) | `README.md` §6 Quick Start(离线回放/真集群/LLM 三种模式);`moon test` 51/51;`eval/scripts/run-all.sh` 可重复执行 |
| 工作有效(实质新增) | W1–W4 + Phase A/B 全程记录:骨架 → 规则引擎 → LLM 归纳 → Agent 循环 → 归因收窄/数据完整性 → 结构化 Evidence → 评测集;无重复提交/拆分/空提交 |
| 开源合规 | Apache-2.0;依赖声明于 README 与 docs/PROPOSAL.md §7(kubemoon / moonbitlang-async / mizchi-llm 线格式参考,均注明) |
| AI 可解释 | docs/PLAN.md(目标与路径)、本页(标准映射)、README「AI 使用说明」段:开发用 AI 辅助,诊断内核为确定性 MoonBit 代码,产品内 LLM 仅为可选叙述层 |

## 2. 材料索引

| 材料 | 位置 |
|---|---|
| 项目申报书(官方 8 节模板) | docs/PROPOSAL.md |
| 架构与工作原理 | README.md §4–§5(含包依赖硬约束) |
| 快速开始 | README.md §6 |
| 3 分钟演示脚本 + 评委问答 | docs/DEMO.md |
| 评测集(5 场景 manifest / 真实采集快照 / golden 断言) | eval/(README + scenarios + fixtures + expected + scripts) |
| 评测结果(最近一次离线回放输出) | eval/results/*.out.json |
| 真 LLM × 真集群端到端实测记录 | docs/E2E-REAL-LLM.md |
| 开发计划与执行勾账 | docs/moonmedic_冲刺开发计划.md + docs/PHASE-A-B-CHECKLIST.md |
| CI | .github/workflows/ci.yml(fmt --check / check / test;push 与 PR 触发) |

## 3. 提交前自查

- [x] `moon fmt --check` / `moon check` / `moon test` 全绿(51/51)
- [x] `eval/scripts/run-all.sh` 5/5 PASS(离线,可重复)
- [x] README 测试数量、功能状态与实际一致
- [x] 无未说明的集群写操作(全程 GET;评测 namespace 隔离且已清理)
- [x] 版本、许可证、第三方依赖、AI 使用说明齐备
- [ ] 验收提交动作:按赛事官方通知执行(截止以官方通知为准;详见赛事群与章程)

## 4. 已知限制(如实声明)

见 README §9:LimitRange 完整约束回放、CPU/内存配额差额计算、调度器级节点分析、
部分规则的文本级证据(sched/probe,v1 限制)均如实标注,未宣称未经验证的功能。
