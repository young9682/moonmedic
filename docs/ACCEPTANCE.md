# moonmedic 验收与复现

提交正文见[八项项目申报书](项目申报书.md)。[评审答复与基线](PROPOSAL.md)提供技术边界、反例和外部来源。

## 最短复现路径

准备 MoonBit 工具链、已解析的依赖、Bash 和 Python 3。以下验证使用仓库快照，无需集群或模型端点。

```bash
moon fmt --check && moon check && moon test  # 53/53
bash eval/scripts/run-all.sh                 # pass=9 fail=0
moon run cmd/main -- --snapshot eval/fixtures/e01-quota-zero-pods.snapshot.json --json
```

| 评分维度 | 可检查的交付 |
|---|---|
| 工程深度与实现强度 | E01、E02 分别验证零副本与部分副本。E05 模拟 Pods 读取失败。实时取证入口为 `--deployment`。 |
| 技术贡献与攻关 | MoonBit 的类型化拒绝分类、UID 归属、列表完整性和配额数值关联。配额名称、受限资源和副本差额都有可查的字段证据。 |
| 生态增量 | 可复用的快照、结构化诊断和 JSON 回放。kubectl、K8sGPT 与 HolmesGPT 的官方能力及同场景实测边界见[基线表](PROPOSAL.md#外部基线)。 |
| 开发与验证能力 | 53 个单测、9 个离线场景。GitHub Actions 执行格式、类型、依赖边界、单测及场景回放。R01 至 R04 固化本轮复查发现的误报。 |

[场景来源与复现](../eval/README.md) · [CI 定义](../.github/workflows/ci.yml) · [历史真实集群及 LLM 实测](E2E-REAL-LLM.md)

作者：young86
