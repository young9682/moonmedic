# Kubernetes 诊断同场景对照

## 场景与口径

选用 E01、E02 和 R01–R04。E01、E02 来自先前的 RKE2 注入采集，另外四个是构造的离线反例。运行器为每个场景启动独立的回环 HTTP 服务，将原有快照以 Kubernetes 读取接口返回，并为工具生成临时 kubeconfig。它提供资源发现、单对象读取、列表和简单等值选择器。这个对照验证工具在保存的证据上的表现。真实集群版本差异、鉴权和延迟需要另外测试。

- **kubectl v1.33.0**。依次执行 Pod 列表、Deployment 详情、ReplicaSet 详情、ResourceQuota 详情和事件列表。记录它呈现的原始材料。
- **K8sGPT v0.4.41**。运行 `analyze --filter Pod,ReplicaSet,Deployment --output json --no-cache`。使用本地分析器，关闭模型解释。结果同时检查分析器消息和实际读取的 API。
- **HolmesGPT 0.46.0**。运行上游 `ask`，仅启用内置 `kubernetes/core`。首轮由模型构造字段查询。复核轮给同一模型固定的只读字段投影，观察取证错误与归因错误的差别。两轮均使用相同的六份快照，逐份发起独立会话。Windows 适配将上游的 POSIX 脚本交给 Git Bash。
- **moonmedic**。使用原有 `--snapshot <file> --json` 路径，记录规则、分层和证据。四个反例的预期已经由仓库回归掌握。

将“Pod 已创建”和“副本可用”分别核对。区分拒绝记录里的历史数值与当前 ResourceQuota 表。对于 R01–R03，单独检查是否把缺少声明、通用校验或 Webhook 拒绝归为配额或 LimitRange。对于 R04，检查是否保留明确的配额拒绝，是否错误地从不匹配的资源推算差额。kubectl 的输出按人工取证材料记录。模型输出按本次运行读解。

## 2026-11-18 实测结果

六个场景的命令均完成。两轮 HolmesGPT 共得到 12 份报告。关键输出、Kubernetes 请求轨迹、工具错误以及模型作答见[实测记录](results/baselines-2026-11-18.json)。

| 场景 | kubectl v1.33.0 | K8sGPT v0.4.41 | HolmesGPT + Qwen3-4B | moonmedic |
|---|---|---|---|---|
| E01 · 零 Pod | ReplicaSet 显示 0 current / 2 desired，配额表为 0/0，事件给出拒绝。 | 报告 2 期望 / 0 可用，并保留 `zero-pods` 的拒绝。 | 首轮识别配额拒绝，但误报 Deployment 与 ReplicaSet 不存在。固定投影后确认零 Pod，建议 `hard ≥2`。 | 引用当前配额与归属计数，给出缺 2 个、`hard ≥2`。 |
| E02 · 部分副本 | 列出 1 个 Pod，ReplicaSet 显示 1 current / 2 desired，配额表为 1/1。 | 报告 2 期望 / 0 可用，并保留 `one-pod` 的拒绝。这个可用副本指标和已创建 Pod 数是两项数据。 | 首轮把空投影与错误命名空间读成资源不存在。固定投影后正确找到唯一的 Pending Pod 和配额 1/1，给出提高上限的定性建议。 | 引用已创建 1 个及当前 1/1，给出缺 1 个、`hard ≥2`。 |
| R01 · 缺资源声明 | 提供 `must specify` 原文和当前 `pods=3/10`。 | 原样保留缺少 CPU requests/limits 的消息。 | 固定投影后说明缺 CPU requests/limits，并与配额耗尽区分。 | 保留创建失败与原始消息，并提示补齐声明。 |
| R02 · 通用校验 | 保留 `Invalid value`，配额列表为空。 | 原样保留通用校验消息。 | 两轮均解读为模板校验失败，未归为 LimitRange。 | 保留创建失败与零 Pod，LimitRange 根因缺席。 |
| R03 · Webhook 与饱和共存 | 提供 Webhook 拒绝和 `compute/pods=10/10`，可分开核对。 | 保留 Webhook 拒绝。 | 两轮均识别 Webhook，没有归因为配额耗尽。 | 配额饱和作为相关提示，原始 Webhook 拒绝保留在机制证据。 |
| R04 · 配额状态不匹配 | 事件点名 `compute/pods`，当前表中 `compute` 只有 `requests.cpu`，`other-quota` 才含 `pods`。 | 保留 ReplicaSet 状态里的拒绝，请求轨迹未读取当前 ResourceQuota。 | 两轮均把拒绝里的 `pods=10/10` 说成当前 `compute` 的限制。固定投影执行成功，也取得了两份配额对象。 | 保留明确拒绝，当前资源佐证和差额缺席。 |

K8sGPT 的三个分析器在六个场景都拿到了 Deployment 或 ReplicaSet 症状和拒绝文本。请求轨迹显示这组分析器从对象状态取证，未读取 ResourceQuota，也未输出配额差额。R01–R03 保留的拒绝文本与快照一致。

HolmesGPT 首轮出现过 jq 遍历空字段、投影无匹配、错误命名空间三类取证问题。固定投影后，六个场景共 30 次资源查询均到达预期命名空间并获得可用结果。E01 与 E02 的差异由此变得可见。R04 固定投影后的错误属于证据解读。该结果对应本次模型、提示词和版本组合，可用于解释故障模式。

本轮实测支持的项目增量是固化证据关联、缺失副本差额及弃权判据。E02 和 R04 分别展示数字推算和避免错误佐证。样本共六份，覆盖率与性能需要更大规模的验证。

## 滚动发布同场对照

2026-11-21，三款外部 CLI 和 moonmedic 分别读取同一组 A–E 快照。目标都是新版 3 个可用、旧版退出。初态为旧版 3 个可用、新版期望 1 个但实际为 0，另有 1 个外部 Pod 占位。A 的配额用量为 4/4，策略为 `maxSurge=1`、`maxUnavailable=0`。B–E 各自相对 A 只改一项，五份快照均无拒绝事件。本轮测的是工具对已保存状态的解读。集群随时间的变化另有 [C、D 现场观测](results/rollout-kind-v1.33.1.json)。

| 相对 A 的改动 | kubectl 显示的输入 | K8sGPT 本地分析器 | HolmesGPT + Qwen3-4B 的回答 | moonmedic 的模型输出 |
|---|---|---|---|---|
| A · 基准 | 策略 1/0，配额 4/4 | 副本告警 | 判断可完成，认为满额仍可创建新版。 | 受阻。无法创建新版，也没有可先退的旧副本。 |
| B · 只把 surge 调到 2 | 策略 2/0，配额 4/4，新 RS 期望 1、实际 0 | 与 A 相同 | 判断可完成，提到最低可用数限制，却认为 4 个名额足够，建议等待新版。 | 受阻。搜索到新版期望数升至 2、实际仍为 0，最低可用数为 3。 |
| C · 只把 unavailable 调到 1 | 策略 1/1，配额 4/4，新旧 RS 的计数与 B 相同 | 与 A 相同 | 判断可完成，给出的第一步是先创建新版；这个动作在 4/4 时无法执行。 | 可达。先退 1 个旧副本，释放名额后创建新 Pod，待它可用再继续。 |
| D · 只把配额上限调到 5 | 策略 1/0，配额 4/5 | 与 A 相同 | 判断可完成，建议三个新版都创建后再退旧，当时只空出 1 个名额。 | 可达。先创建 1 个新版，待其可用后退旧，再用释放的名额替换。 |
| E · 只给外部 Pod 添加删除时间 | 策略 1/0，配额 4/4，外部 Pod 有删除时间 | 与 A 相同 | 判断可完成，明确答复无外部依赖。 | 依赖外部名额释放。外部 Pod 持续占位时受阻，实际释放后才有路径。 |

表中策略依次为 `maxSurge/maxUnavailable`。kubectl v1.33.0 用五次 `get` 显示 Deployment、RS、Pod、配额和事件字段，操作人员可据此自行判断。K8sGPT v0.4.41 的 Pod、ReplicaSet、Deployment 分析器在五例都报告期望 3、运行可用 0，访问轨迹中均未读取配额。精简快照保留了 `availableReplicas=3`，省略了该版本生成告警所用的 `readyReplicas`。因此“0”应按这个输入条件解读。[上游 Deployment 分析器](https://github.com/k8sgpt-ai/k8sgpt/blob/v0.4.41/pkg/analyzer/deployment.go#L50-L73)

HolmesGPT 0.46.0 每例使用新的会话，同一提示词问现行策略能否完成替换，并要求给出动作顺序和外部依赖。提示词提供相同的模型假设和五组字段查询。25 次查询全部成功，B、C 的返回值均含策略、3 个旧 Pod、外部占位和配额 4/4。两次都答可完成，B 的结论和 C 的第一步分别与可核查的约束冲突。这是单一模型、每例一次的观察。CLI 退出码均为 0。[五例逐项输出、实际查询返回和完整模型回答](results/rollout-baselines-2026-11-21.json)

## 复现命令

准备上述三个版本和 MoonBit 工具链。HolmesGPT 在独立的 Python 3.12 环境中安装，Kubernetes 工具需要 Bash、kubectl 和 jq。

```bash
python3.12 -m venv /tmp/moonmedic-holmes
/tmp/moonmedic-holmes/bin/python -m pip install holmesgpt==0.46.0
python eval/scripts/compare-baselines.py --output /tmp/moonmedic-results \
  --holmes /tmp/moonmedic-holmes/bin/python \
  --k8sgpt /path/to/k8sgpt --model-url http://127.0.0.1:18081/v1
python eval/scripts/compare-baselines.py --output /tmp/moonmedic-fixed \
  --tools holmes --holmes-fixed-queries --holmes /tmp/moonmedic-holmes/bin/python
python eval/scripts/compare-baselines.py --suite rollout --output /tmp/moonmedic-rollout \
  --k8sgpt /path/to/k8sgpt --holmes /tmp/moonmedic-holmes/bin/python --holmes-fixed-queries
```

本次使用 Windows CUDA 后端。本地模型为 [Qwen3-4B-Instruct-2507 Q4_K_M](https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/tree/a06e946bb6b655725eafa393f4a9745d460374c9)，GGUF 的 SHA-256 为 `3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597`。使用 [llama.cpp b12499](https://github.com/ggml-org/llama.cpp/releases/tag/b12499) 启动本机服务。

```bash
llama-server -m Qwen3-4B-Instruct-2507-Q4_K_M.gguf \
  --alias qwen3-4b-instruct-2507 --host 127.0.0.1 --port 18081 \
  -ngl 99 -c 12288 -b 512 -ub 256 -fa on --parallel 1 \
  --jinja --reasoning off --seed 42 --no-webui
```

Windows 下将 `--holmes` 指向虚拟环境的 `Scripts/python.exe`，再传入 `--git-bash <Git Bash 路径>` 和 `--jq <jq.exe 路径>`。可用 `--tools` 指定部分工具，或用可重复的 `--scenario` 参数选择场景。保存的每份 JSON 含 CLI 退出码、标准输出、错误和读取轨迹。

作者：young86
