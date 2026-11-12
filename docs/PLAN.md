# moonmedic 技术方案(W0 规划稿)

> 状态:设计定稿,开发未开始 · 2026-11-13
> 本文档是 moonmedic 的目标与路径说明,随开发进展持续更新。

## 0. 定位与边界

**一句话**:MoonBit 写的 Kubernetes 只读排障 Agent —— 输入问题现象,输出"证据链 + 根因假设 + 修复建议"的 Markdown 诊断报告。

**非目标(本期明确不做)**:
- 不对集群做任何写操作(不 restart / scale / patch,修复建议只输出不执行)
- 不做 Web UI / TUI(CLI 优先,TUI 作为下赛季可选项)
- 不做写操作类工具的"确认后执行"模式(留给未来,本期只读是硬边界)

## 1. 总体架构

```
┌───────────────────────────────────────────────────┐
│ cmd/main(CLI)                                     │
│   入参:namespace/pod 名 或 问题描述;输出:报告     │
├───────────────────────────────────────────────────┤
│ medic(诊断编排器)                                 │
│   Agent loop:①规则初筛 → ②LLM 推理 → ③工具调用    │
│   循环直到收敛(步数上限 N=8)                      │
├────────────────────────┬──────────────────────────┤
│ tools(只读工具层)      │ llm(LLM 层)              │
│ kubemoon 动态客户端桥接 │ mizchi/llm Provider       │
│ 白名单 + 输出裁剪       │ OpenAI 兼容,可换端点     │
├────────────────────────┴──────────────────────────┤
│ rules(诊断知识库,表驱动)  report(Markdown 渲染) │
└───────────────────────────────────────────────────┘
```

**分层诊断设计(本项目核心决策)**:

1. **规则层(rules)**:纯 MoonBit、确定性、表驱动。把 Pod 状态机
   (waiting/terminated、exitCode、reason)、Events、Owner 链映射为
   结构化 `Finding(rule_id, confidence, evidence_refs)`。
   → 保证**没有 LLM 也能给出初诊**,且 100% 可单测。
2. **LLM 层(medic + llm)**:把规则层初筛结果 + 工具取回的原始证据交给
   LLM 归纳,输出人类可读报告(讲人话、跨信号联想、给修复建议)。
   → LLM 失败/超时/输出不合规时,**降级为规则层输出**,系统永远有结果。

这个分层同时是评测的分层断言点(见 §5)。

## 2. 技术栈(全部 mooncakes 现成生态)

| 依赖 | 用途 | 关键 API |
|---|---|---|
| `cxh04/kubemoon@0.1.1` | 集群访问 | 动态客户端(GroupVersionResource + Scope)、get/list、原生 HTTP/TLS、Bearer Token、`ClientConfig.ca_file` |
| `mizchi/llm@0.3.2` | LLM + agent 地基 | `Provider` trait(流式)、`ToolRegistry`/`ToolDef`/`SchemaBuilder`(工具+JSON Schema) |
| `moonbit-community/yaml` | 评测场景 manifests | 解析 |
| `moonbitlang/async` | native 异步 IO | kubemoon 底层依赖 |
| (远期)`guiqi695/moon-prometheus-sdk` | 指标证据 | 本期只做 Prometheus HTTP API 的最小只读查询,或留到下赛季 |

## 3. 只读工具集(白名单强制)

护栏设计:**工具注册即白名单**,LLM 只能"选择工具 + 填参数",执行权在编排器;
所有工具输出有统一 size 上限(防上下文爆炸);kubemoon 侧天然不签发写请求。

| 工具 | 数据源(kubemoon GVR) | 输出裁剪策略 |
|---|---|---|
| `get_pod(ns, name)` | core/v1 pods | 状态机、容器状态、重启次数、QoS、资源 |
| `list_pods(ns, selector?)` | core/v1 pods | 字段裁剪 + 条数上限 |
| `get_events(ns, fieldSelector)` | core/v1 events | 时间倒序 + 条数上限 |
| `get_logs(ns, pod, container?, tail)` | pods/log 子资源 | 默认 tail=100,单容器 |
| `get_deployment(ns, name)` | apps/v1 deployments | 副本/策略/镜像 |
| `get_replicaset(ns, selector)` | apps/v1 replicasets | Owner 链追溯 |
| `get_node(name)` | core/v1 nodes | conditions、allocatable |
| `get_quota(ns)` | core/v1 resourcequotas + limitranges | 配额余量 |

## 4. 诊断知识库(rules,表驱动)

规则输入:Pod 状态机 + Events + Owner 链(+ 可选日志关键词)。
规则输出:`Finding(rule_id, confidence, evidence_refs, next_tools)`。

首发规则(按演示优先级):

| rule_id | 触发条件 | 结论方向 |
|---|---|---|
| `oomkilled_limit` | exitCode=137 ∧ reason=OOMKilled | 内存 limit 过低 / 泄漏,建议查 limit 与趋势 |
| `crash_exit_1` | CrashLoopBackOff ∧ exitCode=1 | 应用崩溃,引日志尾部 |
| `sched_insufficient` | FailedScheduling(insufficient cpu/memory) | 节点资源/配额不足 |
| `image_pull_tag` | ErrImagePull ∧ tag 相关 message | 镜像名/tag 错误 |
| `image_pull_secret` | ErrImagePull ∧ auth 相关 message | imagePullSecrets 缺失/失效 |
| `probe_fail_path` | Unhealthy ∋ probe failed(404/conn refused) | 探针路径/端口/启动慢(建议 startupProbe) |

知识库是**数据不是代码**:规则=表项(条件谓词 + 结论模板),新增场景=加表项 + 单测。

## 5. 评测方案(验收核心)

- **环境**:本地 `kind` 集群;`eval/` 目录 = 每场景一个故障 manifest + 注入脚本 + 断言
- **故障注入场景 ≥6**:OOMKilled(limit 设 32Mi 跑 stress)、坏镜像 tag、缺 ConfigMap 键、探针路径 404、namespace 配额打满、exit 1 死循环
- **双层断言**:
  - 规则层:`moon test` 确定性单测(喂 fixture 状态 → 断言 rule_id 命中),CI 必跑
  - 端到端:注入故障 → 跑 moonmedic → 断言报告含关键词、工具调用轨迹含必备工具
- **录制回放**:LLM 响应录制为 fixture,CI 无 API key 离线跑端到端结构
- 无集群/无 Docker 时,评测退化为 fixture 单测(工具层用脚本化 HTTP Server 桩,kubemoon 自带此模式)

## 6. 包结构(moon 新版扁平规范)

```
moonmedic/
├── moon.mod            # young9682/moonmedic
├── cmd/main/           # CLI 入口
├── medic/              # 诊断编排器:agent loop、会话、步数上限
├── tools/              # kubemoon 桥接、白名单注册、输出裁剪
├── rules/              # 诊断知识库(表驱动)+ 单测
├── llm/                # mizchi/llm 适配:Provider 配置、结构化输出、降级
├── report/             # Markdown 报告渲染
└── eval/               # 场景 manifests、注入脚本、fixtures、回放
```

(目录名随 moon 包机制在 W1 微调;`moon.mod` 依赖声明用 `moon add` 固定版本)

## 7. 周计划

| 周 | 产出 | 验收线 |
|---|---|---|
| W1 | moon 骨架入库;kubemoon 连通 PoC:读 kind 集群 pod 列表 | `moon run` 能打印本机集群 pods |
| W2 | tools 全部 8 个只读工具 + rules 前 3 条 + CLI 参数 | CrashLoop 场景**纯规则层**端到端出报告 |
| W3 | llm 层接入 + report 渲染 + 评测框架;场景扩到 6 个 | LLM 报告 + 规则降级双通路可用;录制回放可跑 |
| W4 | 文档、CI(moon check/test/info)、演示录屏、README 终稿 | 提交验收材料 |

开发纪律:每周至少一次里程碑 push;小步提交;提交信息干净。

## 8. 风险与对策

| 风险 | 对策 |
|---|---|
| MoonBit 新手,语言/生态不熟 | W1 只做最小 PoC;AI 辅助开发但每行提交前自己过一遍(官方允许 AI 辅助,质量自持) |
| kubemoon 0.1.1 API 覆盖不足(如 pods/log 子资源) | W1 连通时即验证缺口;缺口小→本仓库封装;缺口大→给上游提 PR(黑客松认可可追溯的上游贡献) |
| LLM 输出不稳定 | 结构化输出 schema 校验 + 1 次重试 + 规则层兜底降级 |
| 工具输出撑爆上下文 | 统一裁剪上限 + 分页参数 |
| Windows 本机无 kind/Docker | 评测以 fixture 单测为主,kind 场景本地选跑;或 WSL2 跑 kind |
| 本月时间不足 | 场景优先级:CrashLoop > Pending > 镜像 > 探针;指标查询工具标记为 stretch |

## 9. 官方验收对照

| 验收项 | 本方案 |
|---|---|
| MoonBit 为主 | 全部实现语言为 MoonBit;评测注入脚本仅为胶水 |
| 仓库公开、提交可追踪 | github.com/young9682/moonmedic,小步持续提交 |
| 能运行 | `moon run cmd/main`;README 提供可复现演示 |
| 工作有效 | 本期为全新实质开发,无拆分/重复提交 |
| 开源合规 | Apache-2.0;依赖均在 README/本文档声明 |
| AI 可解释 | 本文档公开目标与路径;AI 辅助产出由作者审核把控 |
