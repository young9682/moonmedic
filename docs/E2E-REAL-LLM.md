# 端到端实测记录:DeepSeek(deepseek-flash 网关路由)× 真实 RKE2 集群

- 日期:2026-11-14
- 目标:kube-system/csi-nfs-controller-86c986f847-b9spg(多容器、带历史重启的健康 CSI 控制器 Pod)
- 配置:MOONMEDIC_DEBUG=1;LLM 走 OpenAI 兼容 chat/completions;全程只发 GET

## Agent 循环轨迹(MOOMMEDIC_DEBUG=1)

```
[moonmedic][agent] step 1: 调用 get_pod, get_events
[moonmedic][agent]   ↳ get_pod → 189 字符
[moonmedic][agent]   ↳ get_events → 7 字符
[moonmedic][agent] step 2: 调用 list_pods
[moonmedic][agent]   ↳ list_pods → 1886 字符
[moonmedic][agent] step 3: 调用 get_pod, get_logs
[moonmedic][agent]   ↳ get_pod → 1518 字符
[moonmedic][agent]   ↳ get_logs → 1517 字符
[moonmedic][agent] step 4: 调用 get_logs
[moonmedic][agent]   ↳ get_logs → 1517 字符
```

## 最终诊断报告(模型原文)

```markdown
[moonmedic][agent] step 5: 最终结论(1312 字符)
# moonmedic 诊断报告

- Pod: `kube-system/csi-nfs-controller-86c986f847-b9spg`
- Phase: `Running`

## 结论(LLM 归纳)

**根因**：证据不足，无法确定根因。当前可获取的证据只能确认该 Pod 曾因容器进程以 exit 1 退出而重启 4 次，但没有任何证据指向具体触发原因（例如 OOMKilled、探针失败、leader 选举失败或 CSI 驱动不可用）。

**依据**：
- `get_pod` 返回：phase 为 Running，重启次数为 4，上次终止原因为 `Error(exit 1)`，内存 limit 为 400Mi。注意：`Error(exit 1)` 表示进程自行以非零码退出，**不是** `OOMKilled`，因此不能据此判定内存超限。
- `get_events` 返回“无相关事件”，因此没有 FailedScheduling、Unhealthy、OOM 等事件可供关联。
- `get_logs`（tail 200/500）返回的日志尾部只有正常业务流水：`Detected CSI driver nfs.csi.k8s.io`、`successfully created PV pvc-5f551329-...`、`ProvisioningSucceeded`、`does not need any deletion secrets`，时间跨度为 10-21 至 10-31，**没有 panic、fatal、error 或退出前的堆栈**。日志尾部被截断（共 5964 字符），崩溃现场不在可见范围内。
- 首次 `get_pod` 使用 `kube-system/...` 全名返回 404，说明工具按 name 字段匹配；改用短名后成功，因此对象本身存在，不是对象缺失问题。
- 日志中可见 `attempting to acquire leader lease`，但后续是否成功获取租约、是否因租约丢失而退出，在可见片段中无法确认。

**建议**：
1. 用 `kubectl -n kube-system logs csi-nfs-controller-86c986f847-b9spg --previous` 取上一次容器实例的完整日志（尤其退出前 50 行），这是定位 exit 1 的关键证据。
2. 用 `kubectl -n kube-system describe pod csi-nfs-controller-86c986f847-b9spg` 查看 `Last State` 的 Reason/Exit Code 与 `Events` 段，确认是否伴随 `Liveness probe failed` 或 `OOMKilled`。
3. 检查 leader 选举：确认 `kube-system` 下 csi-nfs-controller 的 Lease 对象（如 `external-provisioner-leader-nfs-csi-k8s-io`）是否被其他副本持有或频繁切换，并核对 `--leader-election` 相关参数与 `--timeout` 设置。

**置信度**：低（仅确认了“进程以 exit 1 退出并重启 4 次”这一现象，根因未取证到）

---
由 moonmedic 生成 · 只读诊断 · +LLM 归纳 · 建议仅供参考
```

## 观察结论

1. 5 步收敛:get_pod+events → list_pods(对比同类 Pod)→ get_pod+get_logs → 追加日志 → 结论
2. 模型主动**排除 OOM 假设**(Error(exit 1) ≠ OOMKilled),遵守了"只依据证据"的提示词纪律
3. 明确标注"证据不足"并给出 SRE 级下一步命令(--previous 日志 / describe / Lease 检查)
4. 工具裁剪、404 自愈(模型误传全名后改用短名)、1500 字符截断均按设计工作
