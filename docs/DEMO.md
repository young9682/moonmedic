# moonmedic 三分钟演示

提前在仓库根目录运行 `moon update` 准备依赖。下面的命令读取仓库快照，可在没有 Kubernetes 集群和 LLM 端点的环境演示。

## 00:00–00:45 三个旧副本正常，新版为什么一直是零

```bash
moon run cmd/main -- --snapshot eval/fixtures/rollout-a-full.snapshot.json
```

快照中目标是 3 个副本，旧版 3 个可用，另一个 Pod 占了第 4 个名额。新版期望有 1 个副本，实际为 0。配额 4/4 且 `maxUnavailable=0` 时，创建和先退旧都受约束。报告会判定受阻，并给出两条可行路径分别需要的配额和可用性条件。

## 00:45–01:45 同一初态的两种做法

```bash
moon run cmd/main -- --snapshot eval/fixtures/rollout-c-retire-first.snapshot.json
moon run cmd/main -- --snapshot eval/fixtures/rollout-d-extra-slot.snapshot.json
```

| 相对第一份快照只改一项 | 模型给出的动作 |
|---|---|
| C · `maxUnavailable` 从 0 改为 1，配额保持 4/4 | 先退一个旧副本，等名额释放后再建新版。最低可用数从 3 降到 2。 |
| D · 配额上限从 4 改为 5，策略保持不变 | 先建一个新版，待它可用再退旧。最低可用数仍为 3。 |

三份快照都没有拒绝消息。MoonBit 核心根据副本、配额和发布策略搜索动作顺序，报告可核对原始对象字段。

## 01:45–02:30 展示自动断言

```bash
bash eval/scripts/run-all.sh rollout-a-full rollout-c-retire-first rollout-d-extra-slot
# pass=3 fail=0
```

断言校验诊断层级、关键证据和可行方案的动作顺序。演示运行的三个场景也在完整的 15 例离线回放和 CI 中执行。[验收命令](ACCEPTANCE.md#从全新检出验证)

## 02:30–03:00 说明实测结果

三副本的配额放宽试验在 kind 集群中达到 3/3。固定配额的单副本试验仅放宽 `maxUnavailable` 后达到 1/1。早期三副本固定配额试验在 540 秒时观测到 2/3，因此这里把案例 C 的完整路径作为模型结果展示。[集群验证与观测记录](ACCEPTANCE.md#真实集群验证)

作者：young86
