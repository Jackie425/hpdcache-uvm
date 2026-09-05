# HPDcache UVM Test Plan

> 当前基线以 `docs/Architecture.md` 和仓库源码为准。

## 当前可执行基线

唯一的默认 test 是 `hpdcache_random_test`。它在 `hpdcache_cva6` 配置下启动 4 个
active CRI requester，每个 requester 并发启动 1000 个 API sequence；每笔 item 的
默认操作为 LOAD/STORE soft 分布。requester 4 属于 stride prefetcher，当前 CSR 固定
为关闭，因此只由 passive agent 观察。

默认 PMA map 为：

| 地址范围 | 属性 |
| --- | --- |
| `0x80000000-0x80002fff` | cacheable |
| `0x80003000-0x80003fff` | uncacheable |

配置启用 WB、关闭 WT。item 仍可生成 AUTO/WB/WT hint，但 RTL 会将 WT hint 强制为
WB。memory model 使用 in-order、zero-delay、无 backpressure、无 error injection。

## 自动检查

- CRI request/response 的 SID、TID、error、abort 和 response routing；
- cacheable response 与 predictor/reference model 的数据比较；
- uncacheable CRI request/response 与 CMI request/response 的顺序和字段比较；
- CMI write address/data burst 配对及 `mem_req_w_last`；
- CMI 读响应拍、写响应和未完成 traffic 的 drain 状态。

编译和优化可通过后，测试结束还必须满足环境 drain；`check_phase` 会报告未匹配的
prediction、actual/expected transaction 或 CMI outstanding traffic。

## 尚未覆盖

当前计划不声明以下功能已经覆盖：AMO/CMO directed 测试、IO PMA、主动 stride
prefetch、memory delay/backpressure/out-of-order/error campaign、reset-in-flight
场景、功能/代码覆盖率、性能采样以及其他 HPDcache 参数配置。

运行 Questa：

```sh
export QUESTA_HOME=/path/to/modeltech
make test CONFIG=hpdcache_cva6 TEST=hpdcache_random_test SEED=1
```
