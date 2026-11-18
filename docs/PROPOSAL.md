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

**验证边界。** Pod 与 ReplicaSet 按 UID 关联，工作负载事件目前按目标及归属 ReplicaSet 的对象名归集。时间戳用于查看记录，采集结果未做跨对象时间一致性校验。相同错误格式被第三方插件复用时，需要操作者核对来源。跨 Kubernetes 版本和未列出的准入插件待验证。格式依据见 [Kubernetes v1.33 ResourceQuota](https://github.com/kubernetes/apiserver/blob/v0.33.0/pkg/admission/plugin/resourcequota/controller.go#L561-L575) 与 [LimitRanger](https://github.com/kubernetes/kubernetes/blob/v1.33.0/plugin/pkg/admission/limitranger/admission.go#L284-L348)。

### 反例回归

| 快照 | 复查前 | 本轮 CLI 回放 |
|---|---|---|
| R01，未饱和配额与 `must specify` | `quota_exceeded`，0.85 | 保留创建失败与零 Pod，配额根因缺席 |
| R02，通用 `Invalid value` | `limitrange_reject`，0.85 | 保留创建失败与零 Pod，LimitRange 根因缺席 |
| R03，Webhook 拒绝与饱和配额并存 | `quota_exceeded`，0.7 | 饱和配额为 `related`，配额根因缺席 |
| R04，拒绝点名的配额与当前资源状态无法对应 | `quota_exceeded`，0.98 | 保留拒绝记录，权重 0.85。当前数值佐证及差额缺席。回归同时设置异名同资源、同名异资源两种干扰。 |

E01 至 E04 是此前在 RKE2 注入后由 kubectl 采集的快照。E05 派生自 E01，用不可用的 Pods 列表验证降级。R01 至 R04 为离线反例。**本轮重新执行的是离线 CLI 和断言，结果 9/9，单测 53/53。** 现场采集的参考流程见[评测说明](../eval/README.md)。

## 外部基线

外部能力来自官方资料。表中 moonmedic 的输出来自本轮回放。外部工具在相同场景下的覆盖率、延迟及人工操作量仍待实测。

| 工具 | 官方能力或本轮实测 | 对照维度 |
|---|---|---|
| kubectl | `describe` 展示资源详情和相关事件。评测集通过 `get -o json` 获取原始快照数据。[官方命令文档](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_describe/) | 多对象原始取证与人工核对 |
| K8sGPT | 资源分析器可以关闭 AI 解释，也支持按资源过滤。[官方文档](https://docs.k8sgpt.ai/reference/cli/serve-mode/) | 同一 Deployment 的分析器结果与关闭模型解释时的输出 |
| HolmesGPT | 提供 Kubernetes 调查工具，并公开持续运行的评测与结果。[Kubernetes 工具](https://holmesgpt.dev/latest/data-sources/builtin-toolsets/kubernetes/) · [官方评测](https://holmesgpt.dev/latest/development/evaluations/) | 同类证据能否保留及基准覆盖 |
| moonmedic | E01、E02 回放验证配额差额和证据字段。R01 至 R04 验证拒绝分流及弃权。 | MoonBit 可复用快照与证据接口、固定输入的离线可验证输出 |

作者：young86
