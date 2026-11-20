# moonmedic 评审答复与技术说明

[八项项目申报书](项目申报书.md) · [复现及验收](ACCEPTANCE.md) · [评测场景](../eval/README.md)

## 对首轮意见的回应

- **扣除客户端和通用 Agent 后的贡献**。MoonBit 核心消费 `ClusterSnapshot`，按 UID 重建工作负载与副本的归属，解释列表可用性，分类创建失败，组合拒绝记录和 ResourceQuota 数值，并输出分层及字段级证据。集群 I/O 和模型接口都在诊断核心之外。
- **Pod 未创建时的证据来源**。以 `moon run cmd/main -- --deployment <ns> <name> --json` 启动。读取目标 Deployment 和命名空间 ReplicaSet，用 `ownerReferences.uid` 关联。查看归属 ReplicaSet 的 `ReplicaFailure=True / FailedCreate` 条件和相关事件。读取 ResourceQuota 的 `status.used/hard`，同时读取 Pod 列表并按 ReplicaSet UID 核对副本数。Pod 列表不可用或截断时报告证据缺口。E01 实际采集到了控制器失败条件、事件、`used=0 / hard=0` 和零 Pod。

## 对第二轮意见的回应

**约束与取舍。** 同一快照走确定性的 MoonBit 诊断路径。错误归因以已观察到的创建拒绝为输入。配额做请求量与快照用量的数值核对。LimitRange 依据 Kubernetes LimitRanger 的部分错误格式归因。快照中的 LimitRange 对象可供查阅。各准入插件参数的完整复算留待后续。

| 拒绝记录 | 诊断 |
|---|---|
| 符合 ResourceQuota 超限格式，且记录中的同一资源满足请求量大于剩余额度 | `quota_exceeded`。只有快照里同名配额的同一资源也满足该条件时，才附数值证据并提高规则权重。 |
| `failed quota … must specify` | 保留创建失败机制和原始消息。提示核对必填 requests 或 limits。 |
| 支持的 Container / Pod LimitRanger min、max 或 ratio 格式 | `limitrange_reject`，输出拒绝消息。 |
| 通用校验、Webhook、RBAC 等未归类消息 | 保留创建失败和可证实的现象。饱和配额可作为 `related` 提示。 |

已佐证的 `pods` 项可根据 `spec.replicas - owned_pod_count` 推算缺失副本所需配额。建议以快照当前用量为前提，报告引用副本数、归属计数和该配额的 `used/hard`。Pod 计数不可用时省略差额。相同资源也可能同时受多条约束，建议只涉及匹配到的配额。规则权重用于区分证据强弱，未做概率校准。

**验证边界。** Pod 与 ReplicaSet 按 UID 关联。事件按 `involvedObject` 的类型和名称匹配，检查已提供的命名空间，并在事件和当前对象均有 UID 时核对 UID。缺少 UID 的旧快照仍可回放，此时无法区分同名对象的不同实例。时间戳用于查看记录，采集结果未做跨对象时间一致性校验。相同错误格式被第三方插件复用时，需要操作者核对来源。跨 Kubernetes 版本和未列出的准入插件待验证。[Event API](https://kubernetes.io/docs/reference/kubernetes-api/core/event-v1/) · [Kubernetes v1.33 ResourceQuota](https://github.com/kubernetes/apiserver/blob/v0.33.0/pkg/admission/plugin/resourcequota/controller.go#L561-L575) · [LimitRanger](https://github.com/kubernetes/kubernetes/blob/v1.33.0/plugin/pkg/admission/limitranger/admission.go#L284-L348)

### 反例回归

| 快照 | 复查前 | 本轮 CLI 回放 |
|---|---|---|
| R01，未饱和配额与 `must specify` | `quota_exceeded`，0.85 | 保留创建失败与零 Pod，配额根因缺席 |
| R02，通用 `Invalid value` | `limitrange_reject`，0.85 | 保留创建失败与零 Pod，LimitRange 根因缺席 |
| R03，Webhook 拒绝与饱和配额并存 | `quota_exceeded`，0.7 | 饱和配额为 `related`，配额根因缺席 |
| R04，拒绝点名的配额与当前资源状态无法对应 | `quota_exceeded`，0.98 | 保留拒绝记录，权重 0.85。当前数值佐证及差额缺席。回归同时设置异名同资源、同名异资源两种干扰。 |

E01 至 E04 是此前在 RKE2 注入后由 kubectl 采集的快照。E05 派生自 E01，用不可用的 Pods 列表验证降级。R01 至 R05 为离线反例，R05 验证同名 ReplicaSet 重建后旧事件不会触发配额误报。**离线 CLI 断言 10/10，单测 54/54。** [评测说明](../eval/README.md)

## 外部基线

2026-11-18 用 E01、E02、R01–R04 共六份快照执行 CLI 对照。三款外部工具访问同一套快照提供的回环 Kubernetes API。E01 和 E02 源自 RKE2 采集，其余四份为离线反例。HolmesGPT 分别使用模型自拟查询和固定字段投影。逐场景结果、版本、提示词和复现命令见[实测报告](../eval/BASELINES.md)，原输出和读取轨迹见[记录](../eval/results/baselines-2026-11-18.json)。

| 工具 | 本轮实测 | 与项目关联的结果 |
|---|---|---|
| kubectl v1.33.0 | E01 列表为空，E02 列出 1 个 Pod。六个场景均可读出控制器事件和配额现状。 | 可由操作者交叉核对，其中 R04 的同名异资源与异名同资源差异可直接从表中看到。[官方命令文档](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_describe/) |
| K8sGPT v0.4.41 | Pod、ReplicaSet、Deployment 分析器在六个场景均保留控制器拒绝。E02 报告 0 个可用副本。 | 本配置的请求未读取当前 ResourceQuota，结果未提供已创建副本对应的配额差额。[官方项目](https://github.com/k8sgpt-ai/k8sgpt) |
| HolmesGPT 0.46.0 + Qwen3-4B | 自拟查询在 E02 漏掉证据。固定投影后核实了 E01 零 Pod 与 E02 唯一 Pending Pod。R03 识别 Webhook。 | 固定投影轮的 E01 给出 `hard ≥2`，E02 给出定性建议。R04 两轮都将历史拒绝中的 `compute/pods=10/10` 当作当前配额限制。[官方工具文档](https://holmesgpt.dev/latest/data-sources/builtin-toolsets/kubernetes/) |
| moonmedic | E01 差 2 个，E02 差 1 个。R01–R03 保留原始拒绝及对应诊断边界。R04 保留拒绝，省略当前数值佐证与差额。 | MoonBit 快照接口和字段证据使配额、资源、归属计数与差额可离线复核。 |

本轮对照支持两个可检查的增量。E02 展示对照已创建 Pod 计数后的差额计算。R04 展示在保留超限记录的同时，对不匹配的当前配额状态弃权。模型结果限定于指定版本、模型与提示词。

作者：young86
