# Phase A/B 验收清单(响应评审驳回)

> 状态:**Phase A 已完成;Phase B 计划中**。
> 当前基线:main 分支 W1–W4 已交付;Phase A 已落地(快照 IR、core/adapter 边界、准入失败规则、`--deployment`/`--json`),38 个测试通过。Phase B 的 kind 评测集尚未开始。
> 维护:young86

## 0. 两条拒稿理由与关闭条件

| 拒稿理由 | 关闭条件 |
|---|---|
| 扣除已有客户端与通用 Agent 后,核心仍是六类状态/关键词匹配及模板建议,工程深度不足 | `core` 包零 kubemoon、零 LLM 依赖,可离线跑完 fixture;配额约束做数值回放,准入错误做归因重建;建议由数值差额计算;新增场景优先加数据不改引擎 |
| 配额超限可能导致 Pod 未创建,申报流程未说明如何取证 | 申报书含 7 步 API 取证链;fixture 与 kind 场景能复现“配额耗尽 → ReplicaSet FailedCreate → 0 Pod”的因果链 |

## 1. Phase A:核心分离 + 准入失败路径

### A1 快照 IR 与包边界

- [x] 新增 `snapshot` 包:`ClusterSnapshot`、对象/事件/配额/LimitRange 的声明式表示;
- [x] 新增 `core` 包:对象图、约束回放、因果链、诊断输出;不 import kubemoon、不 import LLM;
- [x] `tools` 作为唯一的 kubemoon 适配器包,负责 GET → Snapshot;
- [x] `snapshot.ClusterSnapshot::from_json` 作为离线 fixture 适配器;
- [x] CI 增加依赖检查:`core`、`rules`、`snapshot` 不得依赖 kubemoon 或 LLM。

**验收**:`core`、`rules`、`snapshot` 的依赖图中没有 kubemoon/LLM;`moon test core` 在无集群、无网络、无 API key 的环境通过。

### A2 证据模型

- [x] `EventFact{reason, message, event_type, kind, name, count, last_seen}`;
- [x] `ConditionFact{type, status, reason, message}`;
- [x] `QuotaFact{name, hard, used}`;
- [x] `ReplicaSetFact{name, desired, ready, conditions}`;
- [x] `WorkloadFacts` 汇总 Deployment、ReplicaSet、Event、Quota、Pod 计数;
- [x] 事件解析优先使用 API 的 `reason`/`involvedObject`,消息文本只做兼容兜底。

**验收**:事件 JSON fixture 能正确解析 `reason`、`involvedObject.kind/name`、`count`、`lastTimestamp`;畸形事件被跳过且不影响其它事件。

### A3 Quantity 算术

- [x] 支持 `10`、`500m`、`64Mi`、`4Gi`、`2G`、`1e3` 等 K8s Quantity;
- [x] `used` 与 `hard` 比较,输出饱和/未饱和;
- [x] 计算配额使用百分比;
- [x] 计算配额差额与反事实建议(提高多少 hard、降低多少 requests)。

**验收**:数量解析、比较、百分比、差额均有单测;非法数量返回缺失而不是猜测。

### A4 准入失败规则

- [x] `quota_exceeded`:配额饱和 +(`FailedCreate`/`ReplicaFailure` 或缺失 Pod)佐证;
- [x] `quota_at_capacity`:配额饱和但尚未观察到创建失败,作为预警;
- [x] `limitrange_reject`:从 `FailedCreate` 的 min/max 信息识别(完整约束回放 Phase B);
- [x] `replicaset_create_failed`:ReplicaSet `ReplicaFailure=True`;
- [x] `workload_no_pods`:期望副本 > 0 且归属 Pod 数为 0;
- [x] `deployment_stalled`:`ProgressDeadlineExceeded` 或 Deployment `ReplicaFailure`;
- [x] 仲裁:强规则命中时压制弱警告,避免同一事实重复报。

**验收**:`quota-zero-pods` fixture 输出“配额 → FailedCreate → 0 Pod”因果链;`limitrange-reject` fixture 不会误报为配额问题。

### A5 只读工具层

- [x] `get_deployment`;
- [x] `list_replicasets_json`(客户端按 ownerReferences 过滤);
- [x] `list_quotas_json`;
- [x] `list_limit_ranges_json`;
- [x] `list_events_json`(原始事件,由 `rules` 解析为结构化 `EventFact`);
- [x] `list_pods_json`(按 ownerReference 统计);
- [x] 所有工具只发 GET;结果有数量上限与截断策略;namespace 由 CLI 固定。

**验收**:代码审计无写请求;kubemoon 0.1.1 缺少 fieldSelector/subresource 的限制在文档中说明,并有客户端过滤实现。

### A6 编排与 CLI

- [x] `diagnose_workload(ns, kind=Deployment, name)`;
- [x] Pod GET 404 时自动尝试同名 Deployment,报告注明切换原因;
- [x] CLI `--deployment <ns> <name>`;
- [x] CLI `--json`,输出机器可读诊断供评测断言;
- [x] 无 LLM 时输出完整确定性报告。

**验收**:三条命令(列 Pod / 诊断 Pod / 诊断 Deployment)均可运行;`--json` 输出包含 `target_kind`、`findings[].rule_id`、`evidence`、`notes`。

### A7 报告与 LLM 叙述层

- [x] 工作负载报告:目标类型、因果链、配额表、证据缺口;
- [x] LLM 提示词包含工作负载事实与规则初筛;
- [ ] LLM 结论要求引用证据编号;未引用时标注“未绑定证据”(Phase B);
- [x] LLM 不可用/超时/格式不合规时降级为纯规则报告。

**验收**:关闭 LLM 后,配额场景报告仍包含完整证据链与计算建议;开启 LLM 后,确定性结论不被覆盖。

### A8 测试规模

- [x] 现有 18 个测试全部保留;
- [x] 新增:数量解析/比较/百分比/差额;
- [x] 新增:事件解析与结构化字段;
- [x] 新增:配额饱和与 `FailedCreate` 关联;
- [x] 新增:LimitRange 拒绝;
- [x] 新增:缺 Pod 因果链;
- [x] 新增:规则仲裁;
- [x] 新增:`--json` 输出快照;
- [x] 目标:32+ 个测试(当前 38)。

**验收**:`moon fmt --check`、`moon check`、`moon test` 全绿。

## 2. Phase B:可回放评测

### B1 评测语料

- [x] 评测环境:使用真实 RKE2 集群隔离 namespace 替代 kind(`eval/scripts/inject.sh`);
- [ ] 8 个场景 manifest:
  - [x] `quota-zero-pods`(hard pods=0,Deployment 无法创建任何 Pod)—— 真集群注入 + 采集;
  - [x] `limitrange-reject` —— 真集群注入 + 采集;
  - [ ] `oomkilled`(运行时路径,fixture 与真机诊断覆盖);
  - [ ] `pending-insufficient`(单测覆盖);
  - [ ] `image-pull-tag`(单测覆盖,真集群注入待续);
  - [ ] `image-pull-secret`(单测覆盖);
  - [ ] `probe-fail`;
  - [ ] `crash-exit-1`;
- [x] E01–E05 每个场景一份真实 `ClusterSnapshot` 录制与期望诊断(eval/fixtures + eval/expected,离线回放 5/5)。

### B2 Harness

- [ ] `eval/inject.sh`:创建 kind 集群、部署场景、等待故障就绪;
- [ ] `eval/run.sh`:运行 moonmedic `--json`,用 jq 断言 rule_id 与关键证据;
- [ ] `eval/golden/*.json`:黄金输出;
- [ ] 场景失败时输出可复现命令与快照。

**验收**:本地一条命令跑完 8 个场景;每个场景断言“命中规则 + 证据包含关键字段”。

### B3 LLM 录制回放

- [ ] 录制一次真实 LLM 响应为 fixture;
- [ ] 回放时不需要 API key;
- [ ] 断言报告结构、证据引用与降级行为。

### B4 CI

- [ ] 主 CI 保持 `moon fmt --check` / `moon check` / `moon test`;
- [ ] 增加离线 fixture 评测;
- [ ] kind e2e 作为 `workflow_dispatch` 或独立 job,避免拖慢主 CI;
- [ ] 记录 CI 运行链接与结果。

### B5 基准

- [ ] 无 LLM 确定性诊断延迟;
- [ ] 带 LLM 的 token 消耗;
- [ ] 8 场景命中率;
- [ ] 结果写入 `docs/EVAL-RESULTS.md`(如实记录,不虚报)。

### B6 实际发现的错误沉淀

- [ ] `get_pod` 传 `ns/pod` 全名返回 404 → 参数契约回归用例;
- [ ] 多容器 Pod 不带 container 读日志被拒 → 首容器选择回归用例;
- [ ] kubemoon 0.1.1 无 fieldSelector/subresource → 客户端过滤/手工路径回归用例;
- [ ] LLM 曾用 OOM 解释 `Error(exit 1)` → 证据纪律回放用例。

## 3. 总验收清单

- [x] `moon fmt --check` 通过;
- [x] `moon check` 通过;
- [x] `moon test` 全绿,38 个测试;
- [x] `core`、`rules`、`snapshot` 不 import kubemoon;
- [x] `core`、`rules`、`snapshot` 不 import LLM;
- [x] `core` 的 fixture 测试在无集群、无网络、无 API key 时通过;
- [x] 关闭 LLM 后,配额场景报告完整;
- [x] `--deployment` 输出因果链;
- [x] Pod 404 自动切换工作负载;
- [x] `--json` 输出稳定,可被脚本断言;
- [ ] 8 个 kind 场景通过 golden 断言(Phase B);
- [x] 代码审计无写请求;
- [x] README 已同步;
- [ ] PROPOSAL / PLAN / E2E 的 Phase A 状态待同步;
- [x] 未完成事项在申报书中如实标注。

## 4. Phase A 实际发现的问题

- **网络异常未捕获**:连接失败时 `get_raw` / `get_events` / `list_pod_names`
  抛出未处理的 `OSError`,CLI 直接崩溃。已加 `try/catch` 边界,降级为
  “集群请求失败”注记。
- **证据插值缺失**:配额证据字符串里的 `used="{used}"` 未使用 MoonBit 的
  `\{...}` 插值,报告出现字面量。已修复并加断言。
- **配额语义歧义**:仅“used == hard”不足以证明创建失败。拆分为
  `quota_at_capacity`(预警)与 `quota_exceeded`(有 FailedCreate / 缺失 Pod
  佐证的根因),并在仲裁层抑制重复。
- **缺失 Pod 措辞**:网络失败与对象不存在都会导致 `pod=None`。报告改为
  “不可用(不存在或读取失败)”,仅在读到 HTTP 404 时写“Pod 不存在”。
- **事件归属未过滤**:命名空间事件会包含其它 Pod/工作负载的记录。`core` 已按
  `involvedObject.name` 过滤,只保留目标 Pod 或其 Deployment/ReplicaSet 的事件。
- **事件过滤范围过宽(复查发现)**:初版把命名空间里所有 ReplicaSet 的名字都纳入
  过滤,别的 Deployment 的 FailedCreate 仍可能混入。已改为只纳入
  `ownerReferences.uid == Deployment.uid` 的 ReplicaSet,并加回归用例。
- **配额差额高估(复查发现)**:初版用 `spec.replicas` 计算缺口,部分 Pod 已创建时
  会算大。已改为 `desired - pod_count`,只计算还缺的副本。
- **本地假 API 验证**:用假 API Server 跑通 Deployment → RS → FailedCreate →
  Quota → 0 Pod 的完整链路,而不是只依赖 fixture 单测。

## 5. 拒稿理由 → 交付 → 证据

| 拒稿理由 | Phase 交付 | 验收证据 |
|---|---|---|
| 扣除已有客户端后核心不足 | A1 快照 IR + core/adapter 分离 | 删除适配器仍可测试;CI 依赖检查 |
| 扣除通用 Agent 后核心不足 | A2–A4 证据模型 + 配额数值回放 + 因果链 | 无 LLM 报告完整;规则/算术单测 |
| 只有关键词匹配 | A2 类型化事件 + A4 配额回放/LimitRange 识别 | 事件解析单测;LimitRange/Quota 同引擎 |
| 建议是模板 | A3 差额计算 + A6 报告 | 报告含由数值计算出的配额差额 |
| 配额导致 Pod 未创建 | A4 + A5 + A6 + B1 | `quota-zero-pods` fixture/kind 场景 |
| 未说明如何取证 | PROPOSAL §4 场景一 | 7 步 API 取证链 + 报告样例 |
| 验证闭环不足 | B1–B6 | golden、回放、CI、基准、bug 回归 |

## 6. 风险与边界

| 风险 | 对策 |
|---|---|
| kubemoon 0.1.1 无 fieldSelector / subresource | 客户端过滤 + 手工拼路径;文档标注;可选提上游 PR |
| RBAC 读不到 Quota/RS | 报告显式标注证据缺失并降低置信度,不编造 |
| Windows 本机无 kind/Docker | fixture 测试为主;kind 在 WSL2/CI 运行 |
| LLM 输出不稳定 | 录制回放 + 证据编号校验 + 纯规则降级 |
| 时间不足 | 优先 Phase A,再 Phase B;Phase C 明确标注未完成 |
| 把上游能力算作原创 | 申报书 §5.1、§7 明确 kubemoon/mizchi 的能力边界 |

**非目标**:写操作、Web UI/TUI、多集群、告警接入、LLM 诊断准确率承诺。

## 7. 文档同步

- [x] `README.md`:更新定位、场景清单、CLI 用法、评测命令;
- [x] `docs/PROPOSAL.md`:已重写并同步 Phase A 状态;
- [x] `docs/PLAN.md`:保留 W0–W4 历史,补一行说明本轮 Phase A/B;
- [ ] `docs/E2E-REAL-LLM.md`:保留真机记录,补充本轮新增场景;
- [ ] `eval/README.md`:记录 8 场景的运行方式与期望结果(Phase B);
- [ ] `docs/EVAL-RESULTS.md`:记录基准数据与实际发现的问题(Phase B)。

## 8. 评审自检六问

- [x] 删掉 kubemoon 适配器,`core` 还能编译并跑完 fixture 测试?
  (CI 依赖边界 + `core` 离线单测)
- [x] 删掉 LLM,配额场景还能输出完整因果链和计算建议?
  (`core` 单测与 `--json` 输出均不依赖 LLM)
- [x] 新增 LimitRange 场景只加快照数据和断言,没有改引擎?
  (规则表 + fixture,`core` 未新增特殊分支;完整 min/max 回放归 Phase B)
- [x] 申报书有配额场景的逐步 API 取证链?
  (PROPOSAL §4 场景一)
- [x] 有和 kubectl / k8sgpt / HolmesGPT 的外部基线对比?
  (PROPOSAL §7)
- [ ] Harness 发现过真实错误,并把它变成回归用例?
  (已用本地假 API 发现网络异常并修复;kind Harness 待 Phase B)
