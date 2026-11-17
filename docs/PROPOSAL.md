# moonmedic 项目申报书(2026 MoonBit 黑客松 · 十一月赛)

> 本版为评审驳回后的修订版:核心定位由“LLM 排障 Agent”调整为“确定性故障证据引擎 + 可回放基准”,并补入配额超限导致 Pod 未创建时的取证链。W1–W4 与 Phase A(快照 IR、对象图、配额/LimitRange 准入重建、`--deployment`/`--json`)已交付;Phase B(kind 评测集)进行中,见 §5.7、§5.9。

## 1. 项目名称

moonmedic —— MoonBit 原生的 Kubernetes 故障证据引擎与可回放基准

## 2. 项目简介

moonmedic 是一个用 MoonBit 编写的 Kubernetes 只读故障诊断引擎。它把集群对象还原为可离线回放的 `ClusterSnapshot`,沿 `Deployment → ReplicaSet → Pod` 的对象图区分两类故障:**Pod 已存在时的运行时故障**,以及 **Pod 未被创建时的准入失败**。对后者,引擎从 ReplicaSet 的 `ReplicaFailure` 条件、命名空间 `FailedCreate` 事件与 ResourceQuota 的 `hard/used` 做数值重建,并从准入错误中识别 LimitRange 拒绝,给出由证据计算出的配额差额与修复建议。

目标架构中,核心引擎不依赖 kubemoon——kubemoon 仅作为可替换的快照适配器;也不依赖 LLM——LLM 仅作为可选叙述层。所有结论绑定 API 路径、字段与时间戳,可被单测、快照回放和故障注入评测。现有 W1–W4 实现为 MoonBit(native 后端,零 C stub),全程仅发 GET 请求,已在真实 RKE2 集群上完成端到端验证;本轮新增部分沿用同一技术栈。

当前状态:W1–W4(骨架、规则引擎、LLM 归纳、Agent 循环)与 Phase A(核心与适配器分离、准入失败取证、`--deployment`/`--json`)已交付,36 个测试通过;Phase B 的可回放评测集正在进行,详见 §5.7、§5.9。

## 3. 项目方向与通用性说明

方向:AI 应用 / Kubernetes 运维诊断工具。项目的 AI 部分是可选的叙述层;核心是确定性的故障证据引擎与基准。

**3.1 可复用的四层**

1. `ClusterSnapshot` 快照格式:把 Pod、Deployment、ReplicaSet、Event、ResourceQuota、LimitRange 归一为声明式 JSON。实时集群、`kubectl` 导出、录制文件都只是它的来源,诊断核心不感知传输方式。
2. 确定性证据引擎:对象图遍历、类型化事件、Quantity 算术、配额约束回放、因果链与证据溯源。纯 MoonBit、无网络依赖,可离线单测。
3. LLM 叙述层:可选的 OpenAI 兼容客户端,只负责把已有证据归纳成人类可读报告;工具白名单、步数上限、namespace 均由代码固定。
4. 可回放评测语料:每个故障场景一份快照 + 期望诊断 + golden 断言,可复用于其它 MoonBit 云原生工具。

**3.2 扣除已有客户端与通用 Agent 之后剩下什么**

- 扣除 kubemoon:剩下 `ClusterSnapshot` 格式、对象图重建、准入失败重建、Quantity 算术、因果链与评测语料。改版后,`core` 包不 import kubemoon,删除适配器后仍可编译并跑完全部 fixture 测试。
- 扣除 LLM:剩下确定性规则层、证据链、由数值计算出的修复建议、离线报告。LLM 不可用不影响诊断成立。
- 剩余能力不是“六条状态判断”,而是“对 Kubernetes 准入与运行时失败做证据重建”的引擎;新增约束优先新增数据与断言,而不是新增特殊分支。

**3.3 可迁移性**

“快照 → 对象图 → 约束回放 → 因果链 → 证据绑定报告”的范式可平移到数据库巡检、日志分析、CI 失败归因等其它运维场景;LLM 始终只做叙述,不进入证据生成路径。

**3.4 非目标**

- 不对集群做任何写操作(不 restart / scale / patch / delete,修复建议只输出不执行);
- 不做 Web UI / TUI,本期以 CLI 与可回放 JSON 输出为主;
- 不做多集群管理与告警接入;
- 不宣称 LLM 诊断准确率;可验证的是确定性规则层与证据链。

## 4. 预期使用场景

**场景一|配额超限导致 Pod 未创建(本轮重点)**

发布后 Deployment 期望 2 个副本,但集群里一个新 Pod 都没有。`kubectl get pods` 只能看到“没有 Pod”,看不到原因。moonmedic 执行:

```
moon run cmd/main -- --deployment prod payments-api
# 或:moon run cmd/main -- prod payments-api(Pod 404 后自动切换工作负载诊断)
```

取证链:

1. `GET /apis/apps/v1/namespaces/prod/deployments/payments-api`:取 `metadata.uid`、`spec.replicas`、`status.conditions`;
2. `GET /apis/apps/v1/namespaces/prod/replicasets`:按 `metadata.ownerReferences[].uid == Deployment.uid` 客户端过滤;
3. 读取 ReplicaSet `status.conditions[type=ReplicaFailure]`,取 `reason=FailedCreate` 与 `message`;
4. `GET /api/v1/namespaces/prod/events`:过滤 `involvedObject.kind=ReplicaSet`、`reason=FailedCreate`,保留 `count`、`lastTimestamp`;
5. `GET /api/v1/namespaces/prod/resourcequotas`:解析 `status.hard` 与 `status.used`,找出 `used >= hard` 的资源并计算差额;
6. `GET /api/v1/namespaces/prod/pods`:按 ownerReference 统计,确认该 ReplicaSet 下 Pod 数为 0;
7. 输出因果链:配额耗尽(根因)→ ReplicaSet FailedCreate(机制)→ 0 个 Pod(现象)。

报告中的建议由证据计算,而不是模板。例如:

```
ResourceQuota/compute: pods used=10, hard=10
Deployment/payments-api: spec.replicas=2
ReplicaSet/payments-api-7d9f6b: FailedCreate ×3
结论: 还差 2 个 pods 配额;将 hard 提高到 ≥12,或缩容 2 个现有 Pod
```

所有请求均为 GET;任一数据源因 RBAC 不可读时,报告显式标注“证据缺失”,不静默降级。

**场景二|生产 Pod 反复重启**

值班收到告警 → `moon run cmd/main -- prod payments-api-7d9f6b-x2k9l` → 引擎读取 Pod 状态机、事件与日志 → 报告:上次终止 OOMKilled(exit 137)、内存 limit 256Mi、已重启 12 次 → 规则 `oomkilled_limit` 给出初诊,LLM 可选的归纳补充泄漏排查建议。Pod 已存在,走运行时路径。

**场景三|发版后 Pending / 镜像拉取失败 / 探针失败**

- Pending:读取 `FailedScheduling` 事件,报告节点资源或配额缺口(`sched_insufficient`);
- ImagePullBackOff:区分 `manifest unknown`(镜像名/tag 错误,`image_pull_tag`)与 `denied / authentication required`(凭据问题,`image_pull_secret`);
- 探针失败:识别 kubelet `Unhealthy` 事件(`probe_fail`),提示路径/端口/启动慢。

以上运行时规则已有单测;配额场景与 LimitRange 场景将在本轮以 fixture + kind 注入补齐。

## 5. 拟实现的核心功能

**5.1 快照 IR 与适配器边界**

- `ClusterSnapshot`:对象、事件、配额、LimitRange 的声明式表示;
- `tools`:唯一的 kubemoon 适配器包,负责 GET → Snapshot;
- `snapshot.ClusterSnapshot::from_json`:离线 fixture 适配器;
- `core`:零 kubemoon、零 LLM 依赖,输入 Snapshot,输出 Diagnosis。CI 已检查 `core`/`rules`/`snapshot` 不得依赖 kubemoon 或 LLM。

**5.2 对象图与两条诊断路径**

- Pod 存在:运行时路径,读取 status、containerStatuses、Events、日志;
- Pod 不存在:准入路径,从 Deployment 出发,沿 `ownerReferences.uid` 找 ReplicaSet,再按 ownerReference 统计 Pod 数;
- 自动切换:Pod GET 404 时尝试同名 Deployment,并在报告中注明“目标 Pod 不存在,已切换工作负载诊断”。

**5.3 准入失败重建与 Quantity 算术**

- 配额约束回放:用 ResourceQuota 的 `hard/used` 做数值比较,输出饱和资源与百分比;
- LimitRange 拒绝:从 `FailedCreate` 的 min/max 信息识别;完整的 min/max/default 逐条回放列为 Phase B;
- Quantity 解析与比较:`10`、`500m`、`64Mi`、`4Gi`、`2G`、`1e3`,计算配额百分比、差额与“还能创建几个 Pod”;
- 反事实建议:对 `pods` 资源计算“还差几个、hard 提高到多少”;requests.cpu/memory 的模板累加列为 Phase B。

**5.4 类型化事件、因果链与仲裁**

- 事件解析为 `EventFact{reason, message, event_type, involvedObject, count, lastTimestamp}`,优先匹配 API 类型字段,消息文本只做兼容兜底;
- 工作负载规则形成因果链:根因(配额/LimitRange)→ 机制(ReplicaSet FailedCreate)→ 现象(0 Pod);
- 规则仲裁:强规则命中时压制弱警告(例如 `quota_exceeded` 命中后不再重复输出 `quota_at_capacity`);
- 证据缺失:任一数据源不可读时记录缺口,并降低置信度而非编造结论。

**5.5 只读护栏与 LLM 叙述层**

- 工具集只含只读操作,代码层不存在写路径;namespace 由 CLI 固定,LLM 不可控;
- 确定性路径已新增 get_deployment / list_replicasets_json / list_quotas_json / list_events_json 等只读读取;Agent 循环的 LLM 工具白名单仍为 get_pod / get_events / get_logs / list_pods,工作负载取证由确定性路径完成,Agent 扩展列为 Phase C;
- LLM 结论需引用证据编号;未引用时标注“未绑定证据”,不影响确定性报告的成立;
- LLM 不可用、超时或输出不合规时,自动降级为纯规则报告。

**5.6 CLI 与报告**

- `moon run cmd/main`:列出 namespace 内 Pod;
- `moon run cmd/main -- <ns> <pod>`:诊断 Pod;Pod 不存在时自动尝试同名 Deployment;
- `moon run cmd/main -- --deployment <ns> <name>`:诊断工作负载;
- `--json`:输出机器可读诊断,供评测脚本断言;
- 环境变量:集群入口、Token/CA、LLM 端点;所有诊断只发 GET。

**5.7 已交付与本轮补强**

| 能力 | W1–W4 已交付 | Phase A 已交付 | Phase B 目标 |
|---|---|---|---|
| Pod 运行时诊断 | 6 条规则、18 个单测、真机 e2e | 保留并扩展至 36 个测试 | 补 kind 回归 |
| 对象图 / 准入失败 | 无 | 快照 IR、Deployment→RS→Pod、配额数值重建 + LimitRange 识别 | 补 StatefulSet/DaemonSet、完整 LimitRange 回放 |
| CLI | 列 Pod、诊断 Pod | `--deployment`、`--json`、404 自动切换 | golden/评测脚本集成 |
| 评测 | 单测 + CI | core 离线单测 + CI 依赖边界 | 8 个 kind 场景、录制回放、基准 |
| 测试规模 | 18 | 36 | 40+ |
| 规则规模 | 6 条 Pod 规则 | 12+(Pod 6 + 工作负载/准入 6) | 保持并补数据 |

**5.8 开发与验证闭环**

- fixture 回归:数量解析、事件解析、配额饱和、LimitRange、缺 Pod 因果链、规则仲裁、JSON 输出;
- 本地假 API Server 验证:完整跑通 Deployment → ReplicaSet → FailedCreate →
  ResourceQuota → 0 Pod 的链路,不依赖真实集群;
- kind 故障注入(Phase B):配额为 0、LimitRange 拒绝、OOM、Pending、镜像 tag、镜像凭据、探针、CrashLoop;
- LLM 录制回放(Phase B):CI 无 API key 也能跑端到端结构断言;
- 基准(Phase B):确定性诊断延迟、LLM token 消耗、场景命中率;
- 证据校验(Phase B):LLM 结论与证据编号的一致性检查;
- 已发现并修复的真实问题:
  1. `get_pod` 传 `ns/pod` 全名返回 404,暴露工具参数契约不清;
  2. 多容器 Pod 不带 container 读日志被 API 拒绝,修正为首容器选择;
  3. kubemoon 0.1.1 无 fieldSelector/subresource,需客户端过滤与手工拼路径;
  4. LLM 曾试图用 OOM 解释 `Error(exit 1)`,被“只依据证据”的提示词拦住;
  5. 网络连接失败时 `OSError` 未捕获,CLI 直接崩溃;已加 `try/catch` 边界并降级;
  6. 配额证据字符串缺少 MoonBit 插值,输出字面量 `{used}`;已修复并加断言;
  7. 命名空间事件未按目标过滤,可能把别的 Pod/工作负载事件算进来;已按
     `involvedObject.name` 限定到目标 Pod 或其 Deployment/ReplicaSet。

**5.9 未完成事项与范围变化**

- Phase A(核心分离 + 准入路径 + CLI)已落地,36 个测试通过;
- Phase B(Harness + 录制回放 + 基准)尚未开始;
- Phase A 未包含 LLM 证据编号校验与 Agent 工作负载工具扩展,二者归入 Phase B/C;
- Phase C(StatefulSet/DaemonSet、节点容量、上一容器日志、日志签名、提示注入防护)列为可选,若时间不足将明确标注未完成;
- 不把 kubemoon 的能力算作本项目原创;不把 LLM 的叙述能力算作诊断证据。

## 6. 项目性质

原创项目:全部 MoonBit 代码为本仓库原创实现,非移植、非 fork。kubemoon 仅作为集群访问适配器,mizchi/llm 仅作为 agent 线格式参考;两者的能力边界已在 §5.1、§7 明确标注,不计入本项目原创贡献。

## 7. 参考项目说明

**依赖与参考**

- 集群访问:[cxh04/kubemoon](https://mooncakes.io/docs/cxh04/kubemoon)(Apache-2.0),作为可替换的快照适配器;
- 异步 HTTP:[moonbitlang/async](https://mooncakes.io/docs/moonbitlang/async)(Apache-2.0);
- agent 线格式与消息簿记:参考 [mizchi/llm](https://github.com/mizchi/llm)(MIT)的 `run_json_chat_loop`,并适配为异步实现;仅参考设计,不复制其诊断逻辑。

**外部基线对照**

| 方案 | 形态 | 确定性 | 离线 | 可回放 | 准入失败重建 |
|---|---|---|---|---|---|
| kubectl describe/logs/events | 人工命令 | 是 | 是 | 公开资料未见统一语料 | 否 |
| k8sgpt | 分析器 + LLM 后端 | 依赖模型 | 依赖模型端点 | 公开资料未见故障回放语料 | 未强调 |
| HolmesGPT | Agent + 工具 | 依赖模型 | 依赖模型与集群 API | 公开资料未见故障回放语料 | 未强调 |
| **moonmedic** | **确定性引擎 + 可选 LLM** | **核心确定** | **是** | **快照/回放语料** | **是** |

差异定位:上述对照基于截至申报时的公开资料,本项目不宣称全面优于这些工具,而是在“确定性、离线、可回放、准入失败重建”四个轴上填补 MoonBit 生态与现有 K8s 诊断工具之间的缺口。

## 8. GitHub 仓库链接

https://github.com/young9682/moonmedic

main 分支已含 20+ 个有效 commits(持续增长)(W0 计划 → W1 连通 → W2 规则引擎 → W3 LLM 归纳 → W4 Agent 循环 → 规则扩展 → 文档),全部为功能或文档的实质提交,无空提交、无意义拆分或重复提交;所有变更经 PR 合并,提交、评审与 CI 记录完整可追溯。

### 本项目由 young86 开发,最终解释权归于 young86
