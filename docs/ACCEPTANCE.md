# moonmedic v0.1.0 验收与复现

首版提供 Pod 与 Deployment 的只读诊断。Deployment 路径覆盖零 Pod、部分副本、准入拒绝和受配额限制的滚动发布。诊断由 MoonBit 核心生成，Markdown 和 JSON 均可输出。[申报书](项目申报书.md) · [三分钟演示](DEMO.md)

## 从全新检出验证

在仓库根目录运行，准备 MoonBit、Bash 和 Python 3。先刷新依赖索引。依赖准备完成后，单测和快照回放无需集群或模型端点。

```bash
moon update
moon fmt --check
moon check
moon test                                       # 56/56
bash eval/scripts/run-all.sh                     # pass=15 fail=0
python -X utf8 eval/scripts/check-rollout-inputs.py
```

## 验收项目

| 项目 | 可检查的结果 |
|---|---|
| 准入诊断 | E01、E02 分别验证零 Pod 与部分副本。E03 与 R02 对照 LimitRange 拒绝和通用校验失败。E05 验证 Pods 读取不可用时的降级。 |
| 路径分析 | A–E 共五份无拒绝消息的快照。回放校验当前约束下受阻、存在替换路径以及必须等待外部名额释放三种结论。 |
| 恢复方案 | 目标 3 副本、配额 4/4 时，保持最低可用数为 3 需要配额上限为 5。保持配额时可将 `maxUnavailable` 调到 1，最低可用数变为 2。CLI 附模型中的动作顺序和对象字段。 |
| 外部基线 | kubectl、K8sGPT、HolmesGPT 与 moonmedic 同输入运行。对照覆盖六份准入快照、五份滚动发布快照。模型比较限定于记录中的版本、输入与运行次数。 |

[场景与边界](../eval/README.md) · [外部工具对照及输出](../eval/BASELINES.md)

## 真实集群验证

GitHub Actions 在 Kubernetes v1.33.1 kind 集群中复现满额受阻。两个配额上限均为 4 时，只把第一份提高到 5，服务端仍拒绝创建。两份上限都为 5 后，观测到新版 3/3、旧版退出。另一项单副本试验把两个上限保持在 5，只将 `maxUnavailable` 调到 1，观测到新版 1/1、旧版退出。[kind 脚本](../eval/scripts/rollout-kind.sh) · [已通过的主分支运行](https://github.com/young9682/moonmedic/actions/runs/45188671161)

三副本、固定 4/4 的先退旧方案是演示中的模型回放。此前的三副本现场试验在 540 秒观察结束时为新版 2/3、旧版为 0。上面的 1/1 对应另一项单副本试验。[三副本观测记录](../eval/results/rollout-kind-v1.33.1.json)

路径分析要求唯一匹配当前模板的 ReplicaSet、最多一个尚未清空的旧 ReplicaSet、健康的旧版活动副本，以及可核对的无作用域 Pod 数量配额。证据不足或搜索超限时会报告未判定。CPU、内存和带作用域的配额仍在模型范围之外。[支持范围与回归](../eval/README.md#指标口径)

作者：young86
