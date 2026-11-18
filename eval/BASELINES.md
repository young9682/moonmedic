# Kubernetes 诊断同场景对照

## 场景与口径

选用 E01、E02 和 R01–R04。E01、E02 来自先前的 RKE2 注入采集，另外四个是构造的离线反例。运行器为每个场景启动独立的回环 HTTP 服务，将原有快照以 Kubernetes 读取接口返回，并为工具生成临时 kubeconfig。它提供资源发现、单对象读取、列表和简单等值选择器。这个对照验证工具在保存的证据上的表现。真实集群版本差异、鉴权和延迟需要另外测试。

- **kubectl v1.33.0**。依次执行 Pod 列表、Deployment 详情、ReplicaSet 详情、ResourceQuota 详情和事件列表。记录它呈现的原始材料。
- **K8sGPT v0.4.41**。运行 `analyze --filter Pod,ReplicaSet,Deployment --output json --no-cache`。使用本地分析器，关闭模型解释。结果同时检查分析器消息和实际读取的 API。
- **HolmesGPT 0.46.0**。运行上游 `ask`，仅启用内置 `kubernetes/core`。首轮由模型构造字段查询。复核轮给同一模型固定的只读字段投影，观察取证错误与归因错误的差别。两轮均使用相同的六份快照，逐份发起独立会话。Windows 适配将上游的 POSIX 脚本交给 Git Bash。
- **moonmedic**。使用原有 `--snapshot <file> --json` 路径，记录规则、分层和证据。四个反例的预期已经由仓库回归掌握。

将“Pod 已创建”和“副本可用”分别核对。区分拒绝记录里的历史数值与当前 ResourceQuota 表。对于 R01–R03，单独检查是否把缺少声明、通用校验或 Webhook 拒绝归为配额或 LimitRange。对于 R04，检查是否保留明确的配额拒绝，是否错误地从不匹配的资源推算差额。kubectl 的输出按人工取证材料记录。模型输出按本次运行读解。

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
