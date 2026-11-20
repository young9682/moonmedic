# moonmedic 评审答复与技术说明

[八项项目申报书](项目申报书.md) · [复现及验收](ACCEPTANCE.md) · [评测场景](../eval/README.md)

## 第三轮复核中的滚动发布可达性

Deployment 的最终目标是新版全部可用且旧版退出。同样的配额饱和与零个新版 Pod，可以对应不同的完成路径。MoonBit 从快照中识别与 Deployment 模板一致的 ReplicaSet（忽略控制器注入的模板哈希），再以归属 Pod 和配额用量核对初态。状态记录旧版可用数、新版期望数、实际数、可用数，以及正在释放的旧版和外部名额。每一步模拟一次控制器调整、创建、就绪或名额释放。搜索记录前驱以还原动作路径。走遍可达状态才报告受阻，达到 10,000 状态的搜索上限会报告未判定。[搜索实现](../core/rollout_search.mbt) · [Kubernetes 新版扩容](https://github.com/kubernetes/kubernetes/blob/v1.33.1/pkg/controller/deployment/util/deployment_util.go#L759-L778) · [Kubernetes 旧版缩容](https://github.com/kubernetes/kubernetes/blob/v1.33.1/pkg/controller/deployment/rolling.go#L178-L205)

五个无拒绝消息的输入共用同一起点。目标 3，旧版 3 个可用，新版期望 1 个、实际 0 个，外部 Pod 占 1 个名额。基准配额 4/4，整数策略为 surge 1、unavailable 0。

| 唯一变更 | CLI 的模型结论 | 可核查的依据 |
|---|---|---|
| A，沿用基准 | `rollout_blocked` | 无名额可创建新 Pod，3 个可用副本也没有缩容空间 |
| B，surge 增至 2 | `rollout_blocked` | 可以提高新 RS 的期望数，仍创建不了第一个新 Pod |
| C，unavailable 改为 1 | `rollout_reachable` | 可先退一个旧副本，名额释放后创建新版，最低可用数为 2 |
| D，配额上限改为 5 | `rollout_reachable` | 先创建新版并使其可用，再退旧，可保持 3 个可用副本 |
| E，外部 Pod 开始删除 | `rollout_release_required` | 分别搜索占位持续和允许释放两种情形，仅后者有完成路径 |

结论限整数策略、单一无作用域 Pod 数量配额与两个归属 RS，旧版活动 Pod 均可用。模型假定其他常驻负载保持稳定、新 Pod 可以就绪、缩容后最终释放配额。可达性表示存在可行动作顺序，耗时和具体重试时机由实际控制器决定。百分比策略、资源配额组合、列表截断和无法核实的对象状态缺少相应判断条件。[输入检查](../core/rollout_input.mbt) · [五例回放与断言](../eval/README.md)

**案例 C 的现场边界**。Kubernetes v1.33.1 中，配额保持 4，仅将 `maxUnavailable` 从 0 改为 1，新版可用数从 0 增到 2，旧版退到 0。540 秒观察窗口结束时，新 RS 期望 3、可用 2，命名空间实际用量为 3/4。这里观察到了恢复动作，第三个副本的创建尚未观察到。快照无法单独确定控制器何时再次尝试创建。移除现场阻塞快照中的所有事件与控制器条件后，CLI 仍能分别推出原策略受阻和放宽策略后的模型可达路径。[540 秒现场记录](https://github.com/young9682/moonmedic/actions/runs/44673527277)

**案例 D 的现场闭环**。另一套全新 kind 集群中，先观察到旧 RS 的 3 个副本可用，新 RS 期望 1 个、实际 0 个，以及 `FailedCreate` 和配额 4/4。实时 CLI 给出 `rollout_blocked`。在采集快照中单独将配额改为 5，离线 CLI 预测 `rollout_reachable`。随后实际修改 ResourceQuota 的上限，保持 `maxUnavailable=0`，观察到新版 3/3、旧版 0/0、已用 4/5。CI 同时断言这三个终态，并保存 RS 转换记录。[现场运行](https://github.com/young9682/moonmedic/actions/runs/44674774969) · [C、D 观测数据与预测动作](../eval/results/rollout-kind-v1.33.1.json)

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
