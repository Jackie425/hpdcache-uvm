# HPDcache UVM Test Plan

> 当前基线以 `docs/Architecture.md` 和仓库源码为准。

## 当前可执行基线

默认随机 test 是 `hpdcache_random_test`。它在 `hpdcache_cva6` 配置下启动 4 个
active CRI requester，每个 requester 并发启动 1000 个 API sequence；每笔 item 的
默认操作覆盖 LOAD、STORE、全部 AMO 和 CMO。requester 4 属于 stride prefetcher，
当前 CSR 固定为关闭，因此只由 passive agent 观察。

`hpdcache_atomic_test` 是随机原子流 test，使用同一个 vseq/worker 层次。每个
active requester 在 `hpdcache_lrsc_seq` worker 与受约束随机的 AMO API 之间混合
选择。LR/SC worker 通过 AMO API 生成 LR，再直接构造 SC item，并让 SC 复用 LR
的地址、size、byte enable 和 PMA；普通 AMO 的 opcode 由 API 约束生成，覆盖
SWAP、ADD、AND、OR、XOR、MAX、MAXU、MIN 和 MINU。

默认 PMA map 为：

| 地址范围 | 属性 |
| --- | --- |
| `0x80000000-0x80002fff` | cacheable |
| `0x80003000-0x80003fff` | uncacheable |

配置启用 WB、关闭 WT。item 仍可生成 AUTO/WB/WT hint，但 RTL 会将 WT hint 强制为
WB。memory response model 使用 in-order、normal response timing、LIGHT 随机
backpressure；普通 read/write 与 AMO error injection 关闭，write-side
exclusive-fail injection 开启 16 次，用于检查 STEX failure。

## 自动检查

- CRI request/response 的 SID、TID、error、abort 和 response routing；
- cacheable LOAD/AMO/LR response 与 predictor/reference model 的旧值比较；AMO/LR
  优先使用已有 golden-memory byte，只在 byte 未初始化时等待 downstream old value；
- uncacheable CRI request/response 与 CMI request/response 的顺序、字段和 AMO
  atomic 等价性比较；
- CMO 通过 invalidate 后的 golden-memory refill 间接检查；
- prefetch stimulus 覆盖 cacheable/uncacheable PMA 和有/无 response；RTL 对 prefetch
  忽略 PMA uncacheable，predictor 检查 response 状态但不比较 response data；
- CMI write address/data burst 配对及 `mem_req_w_last`；
- CMI 读响应拍、写响应和未完成 traffic 的 drain 状态。

编译和优化可通过后，测试结束还必须满足环境 drain；`check_phase` 会报告未匹配的
prediction、actual/expected transaction 或 CMI outstanding traffic。

## 尚未覆盖

当前计划不声明以下功能已经覆盖：IO PMA、
主动 stride prefetch、memory out-of-order/error campaign、reset-in-flight 场景、
功能/代码覆盖率、性能采样以及其他 HPDcache 参数配置。

运行 Questa：

```sh
export QUESTA_HOME=/path/to/modeltech
make test CONFIG=hpdcache_cva6 TEST=hpdcache_random_test SEED=1
make test CONFIG=hpdcache_cva6 TEST=hpdcache_atomic_test SEED=1
```
