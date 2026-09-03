# HPDcache UVM Test Plan

> 文档基线：2026-09-03，以当前仓库源码为准。架构细节见
> [uvm_architecture.md](uvm_architecture.md)。

## 1. 验证目标

本计划面向固定 CVA6 配置的 HPDcache，目标是在 requester 和下游 memory 两个黑盒
接口上验证：

1. request/response 协议和 SID/TID 路由正确。
2. cacheable load/store 的数据一致性正确。
3. miss、refill、hit、eviction 和 writeback 等 cache 行为在压力与竞争下正确。
4. reset、backpressure、错误返回等异常条件下无丢请求、重复响应或死锁。
5. 多 requester 并发时功能正确且性能满足后续确定的指标。

状态定义：

- **已实现**：已有 test/sequence/checker，可直接运行。
- **部分可达**：现有随机激励可能触发，但没有定向保证或覆盖率证明。
- **待实现**：当前代码中没有对应激励、配置、checker 或采样。

## 2. 当前可执行基线

### TP-SMOKE-001：单笔随机 cacheable load/store

| 项目 | 内容 |
| --- | --- |
| 状态 | **已实现** |
| UVM test | `hpdcache_random_test` |
| Sequence | `hpdcache_random_sequence` |
| Requester | 仅 `agent_0` |
| Transaction 数 | 每次仿真 1 笔 |
| Operation | 随机 `LOAD` 或 `STORE` |
| Address | `0x00000080000000`..`0x00000080000ff8`，8-byte 对齐 |
| Size / BE | 8 byte / 全字节有效 |
| PMA | cacheable、非 IO、physical-indexed |
| Memory | in-order、zero-delay、无 backpressure、无 error |
| 自动检查 | SID/TID、DUT response error、load data、pending/unmatched transaction、drain timeout |

执行方法：

```sh
export QUESTA_HOME=/path/to/modeltech
make random
```

`make random` 使用随机 seed。由于每次只产生一笔且 op 二选一，单次 PASS 不能证明
load 和 store 都被执行；当前也没有 functional coverage 记录随机结果。该测试定位是
环境连通性 smoke，而不是功能回归。

## 3. 自动检查点

当前环境已实现以下基础检查，这些检查会复用于后续 test：

| ID | 检查点 | 检查机制 | 状态 |
| --- | --- | --- | --- |
| CHK-001 | requester 端口号与 request SID 一致 | monitor | 已实现 |
| CHK-002 | requester 端口号与 response SID 一致 | monitor/driver | 已实现 |
| CHK-003 | outstanding TID 不被重复分配 | TID manager/driver | 已实现 |
| CHK-004 | response 能按 SID/TID 路由到原 sequence | driver + sequencer routing | 已实现 |
| CHK-005 | DUT response 不报告 error | evaluator | 已实现 |
| CHK-006 | load 返回值与 shadow memory 一致 | predictor/reference model/evaluator | 已实现 |
| CHK-007 | store 按 byte enable 更新 golden state | reference model | 已实现，但当前 test 不会后接 load 证明结果 |
| CHK-008 | test 结束无 pending prediction/actual/expected | drain + `check_phase` | 已实现 |
| CHK-009 | in-flight signal reset 能解除 sequence/TID 占用 | driver/agent reset handling | 机制已实现，定向 test 待实现 |

当前未检查 response latency、hit/miss 分类、memory writeback 内容、内部 replacement
选择和事件计数。它们需要新增 monitor/checker 或接出 DUT event 信号。

## 4. 功能测试矩阵

### 4.1 基础访问与数据一致性

| Test ID | 场景与主要检查 | 建议激励 | 状态 |
| --- | --- | --- | --- |
| TP-FUNC-001 | cold load miss/refill，返回 backing memory 数据 | 定向单 load，不同地址/line offset | 部分可达 |
| TP-FUNC-002 | 单笔 store 正常响应 | 定向单 store | 部分可达 |
| TP-FUNC-003 | store 后 load 同址，检查 RAW 数据 | store-load sequence | 待实现 |
| TP-FUNC-004 | load hit 返回与首次 refill 一致 | 同址连续两次 load | 待实现 |
| TP-FUNC-005 | 不同 size 与 byte enable 的 partial access | 1/2/4/8-byte，合法 alignment，BE sweep | 待实现 |
| TP-FUNC-006 | cache-line boundary 附近的合法访问 | line 首/尾 word 和相邻 line | 待实现 |
| TP-FUNC-007 | 多地址随机 load/store shadow-memory 一致性 | 长随机 sequence，可配置 transaction count | 待实现 |

### 4.2 Pipeline、outstanding 与 TID

| Test ID | 场景与主要检查 | 建议激励 | 状态 |
| --- | --- | --- | --- |
| TP-PIPE-001 | back-to-back request，无空泡发送 | 单 requester 连续 sequence | driver 支持，激励待实现 |
| TP-PIPE-002 | 多笔 response outstanding | 并行 sequence 或 pipelined sequence | driver 支持，激励待实现 |
| TP-PIPE-003 | 8 个 TID 全部占用后阻塞，第一个释放后继续 | 注入 memory delay，发出至少 9 笔 | 待实现 |
| TP-PIPE-004 | TID 回收和重复使用，response 不错配 | 小 TID 集循环访问 | 基础机制已实现，压力 test 待实现 |
| TP-PIPE-005 | 同一 `{SID,TID}` 复用时保持 request 顺序 | 延迟/乱序组合并重复使用 TID | predictor/evaluator 支持，test 待实现 |

### 4.3 Cache 组织、替换与写回

| Test ID | 场景与主要检查 | 建议激励 | 状态 |
| --- | --- | --- | --- |
| TP-CACHE-001 | 同一 line 不同 word 的 refill/hit | line 内 offset sweep | 待实现 |
| TP-CACHE-002 | 同 set 填满 8 ways 后发生 replacement | 9 个同 index、不同 tag 地址 | 待实现 |
| TP-CACHE-003 | clean victim replacement 不产生错误数据 | 定向 conflict sequence | 待实现 |
| TP-CACHE-004 | dirty victim eviction/writeback 数据正确 | store 8 ways，再访问第 9 个 tag | 待实现 |
| TP-CACHE-005 | partial store 与 refill/writeback byte merge 正确 | partial store + conflict eviction + reload | 待实现 |
| TP-CACHE-006 | 多 set/way 地址分布与随机 replacement 稳定性 | constrained-random conflict traffic | 待实现 |

### 4.4 Hazard 与多 requester 并发

| Test ID | 场景与主要检查 | 建议激励 | 状态 |
| --- | --- | --- | --- |
| TP-CONC-001 | 四个 core requester 独立地址并行访问 | virtual sequence 启动 agent 0..3 | 拓扑已实现，激励待实现 |
| TP-CONC-002 | 多 requester 访问同一 cache line | 同址 load/load、store/load | 待实现 |
| TP-CONC-003 | RAW/WAR/WAW 顺序与最终数据正确 | 定向交错 transaction | 待实现 |
| TP-CONC-004 | MSHR/RTAB/WBUF 压力下无死锁或丢响应 | 并行 miss、store 和 conflict traffic | 待实现 |
| TP-CONC-005 | SID 相同 TID 值跨 requester 并存 | 每个 agent 同时分配相同 TID index | 架构支持，test 待实现 |

### 4.5 PMA、维护操作与预取

| Test ID | 场景与主要检查 | 建议激励 | 状态 |
| --- | --- | --- | --- |
| TP-PMA-001 | uncacheable access bypass 行为 | 可配置 `pma.uncacheable` 的 item/driver | 待实现 |
| TP-PMA-002 | IO access 的 ordering/error 行为 | 可配置 `pma.io` 的定向 sequence | 待实现 |
| TP-CMO-001 | CMO/flush/invalidate 正确完成并影响后续 hit/miss | CMO sequence + event/data checker | 待实现 |
| TP-AMO-001 | AMO/LR-SC 数据及 exclusive 语义 | AMO-aware AXI mapping/reference model | 待实现 |
| TP-PREF-001 | stride 识别后 requester 4 产生正确预取地址 | 可编程 prefetch CSR + passive monitor checker | 待实现 |
| TP-PREF-002 | demand/prefetch 竞争下数据和 replacement 正确 | core traffic + active prefetch | 待实现 |

## 5. Reset 与异常测试

| Test ID | 场景与主要检查 | 建议激励/配置 | 状态 |
| --- | --- | --- | --- |
| TP-RST-001 | idle 时 reset，reset 后可继续访问 | 两段 sequence，中间 phase/signal reset | 待实现 |
| TP-RST-002 | request 等待 ready 时 reset | request backpressure + reset | 待实现 |
| TP-RST-003 | response outstanding 时 reset | memory delay + reset | handling 已实现，test 待实现 |
| TP-ERR-001 | memory read error 传播且不污染 golden data | `insert_rd_error=1` | 待实现 |
| TP-ERR-002 | memory write error 正确上报 | `insert_wr_error=1` | 待实现 |
| TP-ERR-003 | memory response delay/backpressure 下无死锁 | 非 zero-delay，随机 backpressure | 待实现 |
| TP-ERR-004 | out-of-order response 按 ID 正确关联 | out-of-order memory 配置 | 待实现 |
| TP-ERR-005 | global/drain timeout 能报告未完成状态 | 人工阻塞 response | 基础机制已实现，定向 test 待实现 |

## 6. 性能测试计划

当前没有 latency/throughput monitor，也没有采集 DUT event 输出，因此以下项目均为
**待实现**。性能结果必须同时记录配置、traffic、seed、warm-up 区间和采样周期。

| Test ID | 指标 | 场景 | 建议统计方式 |
| --- | --- | --- | --- |
| TP-PERF-001 | Load latency | cold miss 与 warm hit | request handshake 到 response valid 的 cycle 分布 |
| TP-PERF-002 | Store latency | WBUF 空闲与高占用 | request 到 response cycle 分布 |
| TP-PERF-003 | Peak throughput | 连续 load、连续 store、混合 traffic | steady-state accepted requests/cycle |
| TP-PERF-004 | Multi-requester throughput | 1/2/4 requester 同时运行 | aggregate 和 per-requester requests/cycle |
| TP-PERF-005 | Conditional throughput/latency | memory delay、backpressure、miss rate sweep | 按条件分桶统计吞吐和 P50/P95/max latency |
| TP-PERF-006 | Resource saturation | MSHR/RTAB/WBUF 压力 | stall cycle、occupancy proxy、完成率 |
| TP-PERF-007 | Prefetch benefit/cost | stride traffic，prefetch on/off | miss、latency、memory traffic 对比 |

具体性能门限尚无 design specification 输入，不能在当前计划中定义 PASS/FAIL 数值；
在实现 collector 前应先确定目标值和允许误差。

## 7. 覆盖率计划

### 7.1 当前状态

- 没有 SystemVerilog functional covergroup。
- compile filelist 定义了 `HPDCACHE_ASSERT_OFF`，RTL assertion 当前关闭。
- 没有 project-owned protocol SVA。
- `Makefile` 未开启 Questa code coverage 采集或 merge。
- DUT hit/miss、stall、prefetch 等 event 输出目前悬空。

因此当前只能依据 UVM checker 的 PASS/FAIL 判断单次行为，不能声明 feature coverage
closure。

### 7.2 计划 coverpoint

| Covergroup | Coverpoint / Cross |
| --- | --- |
| Request | op、size、BE pattern、alignment、line offset、set、requester SID |
| Address behavior | same word/same line/same set/different set，cold/hit/conflict（需事件或推导） |
| Pipeline | outstanding depth 0..8、TID、back-to-back gap、response latency bins |
| Concurrency | active requester count、same-line sharing、RAW/WAR/WAW x requester pair |
| Memory | read/write、burst length、delay、backpressure、response order、error |
| Cache events | read/write miss、stall、rollback、refill stall、uncached、CMO、prefetch |
| Reset | reset 时 driver state x outstanding depth x operation |
| Feature | cacheable/uncacheable/IO、AMO/CMO/prefetch（功能实现后启用） |

计划以 mandatory functional bins 100% 命中且无 unexpected/illegal bin 为功能覆盖率
closure 条件。code coverage 的 line/branch/toggle/FSM 数值目标需在接入 coverage flow 后，
结合 RTL 可达性和 reviewed exclusion 单独确定。

## 8. Regression 分层

| 层级 | 内容 | 触发建议 | 当前状态 |
| --- | --- | --- | --- |
| Smoke | `TP-SMOKE-001`，单 seed | 每次提交 | 可执行 |
| Basic | directed load/store/RAW/hit/partial access | 每次提交 | 待实现 |
| Nightly random | 长随机、多 seed、1/4 requester | 每日 | 待实现 |
| Stress/error | saturation、reset、delay、backpressure、error | 每日或每周 | 待实现 |
| Coverage | 全测试 merge 和 exclusion review | 里程碑 | 待实现 |
| Performance | 固定 seed/config 基准与趋势对比 | 里程碑 | 待实现 |

随机失败必须至少保留 test name、seed、配置、命令行、UVM log 和 waveform，确保可复现。

## 9. PASS/FAIL 与退出条件

### 9.1 单测试 PASS

单测试至少满足：

1. compile、optimize 和 simulation 进程正常退出。
2. UVM summary 中 `UVM_ERROR == 0` 且 `UVM_FATAL == 0`。
3. 无 DUT error response、SID/TID protocol error 或 load data mismatch。
4. 无 unresolved prediction、unmatched actual/expected transaction。
5. sequence 完成后环境在 10 us 内 drain，且未触发 50 us 全局 timeout。
6. 对 directed test，预期 transaction/check 数必须命中；该计数断言当前尚需实现。

### 9.2 Verification closure

当前项目仍处于最小环境 smoke 阶段，不满足功能签核条件。完整 closure 至少要求：

- 本计划中纳入版本范围的 mandatory tests 全部实现并稳定通过回归。
- mandatory functional coverage 达到 100%，illegal/unexpected bins 为 0。
- code coverage 达到后续批准的门限，所有 exclusion 完成 review。
- 无未关闭的高优先级 checker、protocol、deadlock 或 data-corruption issue。
- 性能门限明确后，所有必测 workload 达标且结果可复现。

## 10. 实施优先级

建议按以下顺序扩展，保证每一步都能增加可证明的验证能力：

1. 增加可配置 transaction count、directed load/store 和 store-load sequence，并对
   `checked_responses` 增加期望计数检查。
2. 增加 back-to-back、多 outstanding、TID exhaustion/reuse 和四 requester virtual
   sequence。
3. 接入 functional coverage 及 DUT event 信号，区分 hit/miss/eviction/writeback。
4. 增加 partial access、same-line hazard、set-conflict eviction 和 dirty writeback test。
5. 开启 memory delay/backpressure/error/out-of-order，完成 reset-in-flight 测试。
6. 最后扩展 PMA、CMO、AMO、prefetch、code coverage 和性能 collector。
