# moonmedic 评测集

## 设计

- **集群采集**。E01–E04 从 RKE2 的隔离命名空间采集。注入脚本应用场景 manifest，采集脚本用 `kubectl get -o json` 组装 ClusterSnapshot。
- **离线派生**。E05 在 E01 的基础上把 Pods 源设为 unavailable。R01–R05 为复查反例构造的最小快照。
- **回放**:`moon run cmd/main -- --snapshot <fixture> --json` 离线诊断,
  不需要集群、网络或 API Key。
- **断言**。`assert.py` 校验必需及禁止的规则 ID，并可按规则检查层级、权重、差额文本和证据引用。CI 运行完整回放。缺失 fixture、CLI 失败或断言失败均返回非零退出码。

## 场景

| ID | 场景 | 验证点 |
|---|---|---|
| e01 | ResourceQuota hard pods=0 | quota_exceeded + workload_no_pods |
| e02 | 配额只允许 1 个 Pod(期望 2) | quota_exceeded(部分副本) |
| e03 | LimitRange max 64Mi < 容器 256Mi | limitrange_reject,禁 quota_exceeded |
| e04 | 同 ns 存在健康外来工作负载 | 归属隔离:broken-api 仍报 workload_no_pods |
| e05 | 真实快照 + Pods 源标记 unavailable | insufficient_evidence,禁 workload_no_pods |
| r01 | 配额要求声明 requests/limits | 保留机制，配额根因缺席 |
| r02 | 通用 Invalid value | 保留机制，LimitRange 根因缺席 |
| r03 | Webhook 拒绝与配额饱和 | 饱和只作为 related 提示 |
| r04 | 异名同资源与同名异资源 | 保留明确拒绝，禁止引用不匹配的配额状态或推算差额 |
| r05 | 同名 ReplicaSet 重建，快照保留旧对象的配额拒绝事件 | 拒绝 UID 不匹配的旧事件，保留新对象的通用校验失败与零 Pod 结论 |

## 前置条件

- MoonBit 工具链、项目依赖、Bash 与 Python 3
- kubectl + 有效 kubeconfig(注入与采集);离线回放本身不需要

## 用法

```bash
eval/scripts/inject.sh e01-quota-zero-pods
eval/scripts/capture-snapshot.sh e01-quota-zero-pods payments-api eval/fixtures/e01-quota-zero-pods.snapshot.json
eval/scripts/cleanup.sh          # 删除全部 moonmedic-eval-* namespace
bash eval/scripts/run-all.sh     # 离线回放 + 断言(不需要集群)
```

## 指标口径

单测 56 项，离线 CLI 回放 15 项。除表中十项外，rollout A–E 使用无拒绝消息的配对快照，每次只变更一项。A 满额受阻，B 增加 surge 仍受阻，C 允许先退旧后可行，D 增加一个 Pod 名额后可行，E 依赖外部终止 Pod 释放名额。可行案例按顺序断言完整动作序列。另有 148 组健康起始状态的可达性校验。运行 `python eval/scripts/check-rollout-inputs.py` 可验证输入边界、百分比策略、历史 RS 和重叠配额。

滚动模型要求唯一匹配当前模板的 RS、最多一个尚未清空的旧 RS，以及健康的旧版活动副本。其他历史 RS 必须满足期望副本为 0、状态计数为 0、无归属的非终态 Pod，输出会列出这些 RS 的证据。仍在终止的旧 Pod 会占用名额，多个旧 RS 尚未清空或证据不足时报告未判定。模型假定其他常驻用量固定、新 Pod 可用、缩容后名额最终释放。搜索达到 10,000 个状态时报告未判定。

配额模型要求同一命名空间内至少有一份配额，且每份仅约束无作用域的 `pods`。逐份检查 `spec.hard`、`status.hard` 和 `status.used`，并与完整 Pod 列表核对用量。搜索使用最低上限，报告列出所有上限等于该值的对象。作用域、其他资源项或任何一份配额的状态不一致都会使路径未判定。离线检查覆盖两份 4/4 并列、只放宽一份、两份都放宽以及无效输入，共 10 例。[Kubernetes 配额准入实现](https://github.com/kubernetes/kubernetes/blob/v1.33.1/staging/src/k8s.io/apiserver/pkg/admission/plugin/resourcequota/controller.go#L408-L492)

当前无法完成替换时，引擎还可反推保持发布策略和外部 Pod 占用所需的最小配额。提高配额只会增加允许创建 Pod 的状态转移，因此可以用可达性搜索二分最小值。报告附该上限对应的路径和所有低于目标的配额对象。搜索或计数超限时，保留当前诊断，最小值报告为未判定。回归还验证了仅有 1 个新版和 1 个外部 Pod 时，有效上限 3 仍受阻、4 可达，当前上限为 2 和 3 的两份配额都需要提高。

快照须包含两项发布参数。百分比按目标副本数折算，`maxSurge` 向上取整，`maxUnavailable` 向下取整。合法策略折算后若两项都为零，最低可用数按允许 1 个不可用副本计算。输出同时保留原策略字段和生效值。[Kubernetes v1.33.1 取整实现](https://github.com/kubernetes/kubernetes/blob/v1.33.1/pkg/controller/deployment/util/deployment_util.go#L814-L840)

CI 的 [控制器实测脚本](scripts/rollout-kind.sh) 使用一次性 Kubernetes v1.33.1 kind 集群，先完成一次发布以保留零副本历史 RS，再检查两个 `25%` 在三副本下的生效值。两个配额满额时先预测仅放宽一份的结果，再用服务端干跑确认另一份配额仍拒绝创建。放宽第二份后验证发布完成。脚本保存各阶段快照、实际准入结果和路径预测。

[外部工具实测](BASELINES.md)覆盖六份准入快照和五份滚动发布快照。后者逐例对照 kubectl 的字段输出、K8sGPT 的告警、HolmesGPT 的回答和 moonmedic 的路径判断。[五例对照及复现方法](BASELINES.md#滚动发布同场对照)
