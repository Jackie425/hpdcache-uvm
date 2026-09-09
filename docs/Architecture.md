# HPDcache UVM 验证架构

> 文档基线：2026-09-07，以当前仓库源码为准。

## 1. 范围

当前环境针对 CVA6 固定参数搭建 HPDcache 黑盒验证，通过 requester 侧 CRI 和
memory 侧 CMI 观察 DUT。已经支持：

- 标准 CRI item 的 LOAD、STORE、AMO、CMO 合法 opcode 空间；
- partial access、`need_rsp`、physical/VIPT、VIPT abort；
- cacheable/uncacheable 以及 AUTO/WB/WT write-policy hint；当前 CVA6 配置只启用 WB，
  RTL 会将 WT hint 强制为 WB；
- cacheable response 预测和 uncacheable CRI/CMI forwarding 对比；
- 4 个 active requester 上的并发随机激励。

`pma.io` 暂时固定为 0。默认 random sequence 使用 item 的 soft 分布，同时覆盖
LOAD、STORE、全部 AMO 和 CMO 操作。

## 2. 固定配置

配置定义在 `config/hpdcache_cva6_config_pkg.sv`，类型定义在
`testbench/types/hpdcache_cva6_types_pkg.sv`。

| 配置项 | 当前值 |
| --- | ---: |
| PA width | 56 bit |
| Sets / Ways | 256 / 8 |
| Cache line | 2 x 64 bit = 16 byte |
| CRI request width | 1 x 64 bit |
| Requesters | 5（4 core + 1 prefetch） |
| SID / TID width | 3 / 3 bit |
| Memory addr/data/ID | 64 / 64 / 4 bit |
| Write policy | WB 开启，WT 关闭 |
| MSHR | 1 set x 8 ways |
| WBUF directory/data | 7 / 7 entries |
| RTAB | 4 entries |
| Low latency / refill feedthrough | 开启 / 开启 |
| ECC / scrubber | 关闭 / 关闭 |

## 3. 配置对象

所有项目自有 config object 都在 `testbench/config/`：

| 对象 | 内容 |
| --- | --- |
| `hpdcache_pma_config` | cacheline 对齐且互不重叠的 PMA region map |
| `hpdcache_cri_agent_config` | active/passive、requester ID、共享 PMA handle |
| `hpdcache_env_config` | 全部 CRI agent config、PMA、memory model 和 active agent 数量 |

base test 在 `build_phase` 创建完整的默认 `hpdcache_env_config` 并 set 给 env。
env 将每个 CRI agent config set 给对应 agent；agent 再 set 给内部 component。
scoreboard 将 PMA handle set 给 predictor 和两个 evaluator。因此所有 CRI agent、
scoreboard、predictor/evaluator 持有的是同一个 PMA 对象。

默认 PMA map 为两个 region：

| 地址范围 | Cacheability | Write policy |
| --- | --- | --- |
| `0x80000000-0x80002fff` | cacheable | 请求 hint；当前 RTL 统一按 WB 处理 |
| `0x80003000-0x80003fff` | uncacheable | 不适用 |

## 4. 顶层和组件树

```text
uvm_test_top (hpdcache_random_test)
`-- env (hpdcache_env)
    |-- clock_driver
    |-- hpdcache_reset_driver
    |-- cri_agent_0 .. cri_agent_3 (active)
    |   |-- sequencer + TID mailbox
    |   |-- driver
    |   `-- monitor
    |-- cri_agent_4 (passive, stride-prefetch requester)
    |   `-- monitor
    |-- cmi_agent (passive)
    |   `-- monitor
    |-- axi2mem_req
    |-- mem_rsp_model
    `-- scoreboard
        |-- predictor
        |   `-- reference_model
        |-- cacheable_evaluator
        `-- uc_amo_forwarding_evaluator
```

顶层保留真实 stride-prefetch wrapper。它 snoop 四个 core requester，但 CSR
输入固定为 0，因此 requester 4 目前只被 passive agent 观察。DUT native CMI
同时接到 passive `hpdcache_cmi_agent` 和既有 AXI/memory model 路径。

## 5. 标准 Transaction

`hpdcache_cri_item` 是唯一 requester transaction 类。随机字段包括 `op`、完整物理
地址、data、BE、size、`need_rsp`、`phys_indexed`、PMA、abort 和 `delay`；SID/TID 由
sequence 分配，response 还携带 `error`、`aborted` 和期望数据的 `data_valid`。

硬约束只描述协议合法性：

- opcode 只取 HPDcache 定义的 LOAD/STORE、全部 AMO、全部 CMO；
- LOAD/STORE 的 size 不超过 requester data width，地址自然对齐，BE 不越过
  `addr/size` 对应的 byte lane，零 BE 也是合法状态；
- AMO size 为 4 或 8 byte、自然对齐、BE 覆盖整个 operand，并强制 response；
- CMO 中被协议实际使用的字段受约束，fence/invalidate/flush 的 don't-care 字段
  不被固定为某一个值；prefetch 同时覆盖 cacheable/uncacheable PMA 和有/无 response，
  RTL 对 prefetch 忽略 PMA uncacheable；
- abort 只允许出现在 VIPT 请求，IO 固定关闭，write-policy hint 只取
  AUTO/WB/WT。

operation 权重是 soft 默认分布，因此 directed sequence 可以直接通过 inline
constraint 选择 AMO/CMO，不需要派生第二种 item。

sequence 在 randomize 前选择 PMA region。item 随后用该 region 约束地址和
`pma.uncacheable`；`wr_policy_hint` 仍作为每笔请求的独立属性随机，但当前
`WT_ENABLE=0`，RTL 会把 WT hint 强制为 WB，因此回归中的有效 cacheable policy
只有 WB。

## 6. VIPT 和 Driver/Monitor

physical-indexed 请求在 CRI 握手拍发送 offset、tag 和 PMA。VIPT 请求在握手拍
发送 offset 和请求属性，在下一拍通过独立 tag pipeline 发送 tag、PMA 和 abort。
request pipeline 与 tag pipeline 并行，因此可连续接受 back-to-back VIPT 请求，
也可逐拍混合 physical/VIPT 请求。

driver clone sequence item，按 TID 保存所有 `need_rsp=1` 的请求上下文。DUT
response 到达后 clone 原 request，补上 response data/error/aborted，并用 UVM
sequence ID 路由回发起 sequence。`need_rsp=0` 在请求完整进入 DUT 后由 driver
产生本地 completion，仅用于让 sequence 释放 TID，不会伪造 monitor transaction。

monitor 在 CRI 握手拍保存所有 request，统一在下一拍通过 `req_ap` 发布。PIPT
request 保留握手拍采集的完整地址/PMA；VIPT request 在发布前合并下一拍的
tag/PMA/abort。response 从独立的 `resp_ap` 发布，只包含 CRI response channel
实际提供的 rdata、SID、TID、error 和 aborted。对于 `need_rsp=1`，monitor 以
`{SID,TID}` 保存 request context，response 到达后组装完整 transaction 并通过
`cri_ap` 发布；`need_rsp=0` 的 transaction 在 request 发布时直接送入 `cri_ap`。

## 7. TID 所有权

每个 active `hpdcache_cri_sequencer` 直接拥有一个容量为 8 的 typed mailbox 和
allocation bitmap，不再存在单独的 TID manager class。sequence 分成三层：

- `hpdcache_base_seq`：只服务恰好一笔 item 的 API sequence；
- `sequences/api/`：保存最小 API，单笔 API 直接继承 base，多笔 API 组合并启动
  多个单笔 API；
- `sequences/worker/`：并发构造和启动 API sequence；LR/SC worker 通过 AMO API
  生成 LR，直接构造 SC item，并在 worker 内复制配对字段；
- `vsequences/`：跨 active requester 编排 worker；test 只配置并启动对应 vseq。

Atomic test 使用 `hpdcache_atomic_seq` 在 `hpdcache_lrsc_seq` worker 和受约束
随机的 `hpdcache_amo_seq_api` 之间随机选择。SC 的地址、size、byte enable 和
PMA 在 worker 内从 LR item 复制；普通 AMO opcode 由 API 自己的约束生成，worker
不复制普通 AMO opcode 列表；`hpdcache_atomic_vseq` 为每个 active requester
启动一个 worker，`hpdcache_atomic_test` 只注入 sequencer、配置 item 数并启动
vseq。

`hpdcache_base_vseq` 保存所有 active CRI sequencer handle。base test 在启动 vseq
前通过 `init_vseq()` 从 env 注入这些 handle，base vseq 在 `pre_start()` 统一检查
queue 非空且所有 handle 非 null。vseq 使用 `start(null)`，不再需要 virtual
sequencer 组件。所选 DV config package 集中定义完整的 RTL 参数，并通过
`HAS_PREFETCHER` 描述 requester 拓扑；启用时约定最后一个 requester 属于
prefetcher，否则全部 requester 由 testbench 驱动。top 和 env config 从这些配置
常量推导一致的类型、参数和拓扑。

单笔 API 的 TID 生命周期为：

1. base `pre_start()` 从目标 sequencer 阻塞 acquire 一个 TID，创建唯一的 `req`，
   选择 PMA region 并设置 SID/TID；
2. API `body()` 直接调用 `start_item(req)`、randomize 和 `finish_item(req)`；item
   的 `delay` 默认随机为 0 到 10，driver 在拉高 request valid 前等待对应周期数；
3. driver 在 DUT response 到达后返回 response；`need_rsp=0` 则在请求完整进入 DUT
   后返回本地 completion；
4. base `post_start()` 取得唯一的 response，检查 SID/TID 后 release TID。

base 不再维护 outstanding map。多个单笔 API 可以共享同一个 sequencer，mailbox
保证 TID 获取和归还原子化，并将实际并发度限制在可用 TID 数量内。

## 8. Predictor 和 Cacheable Evaluator

predictor 消费 CRI request、普通 memory read response 和 monitor 组装完成的 CMI
atomic transaction。STORE 在未 abort 时按 BE 更新 golden memory；LOAD 的期望
有效范围由地址 lane 和 size 决定。cold load 暂存到
`pending_expected_q[{SID,TID}]`，下游普通 memory read response 补齐未知 byte 后再
按同 key 的请求顺序发布。memory model 的 atomic response 不直接更新 reference
model；CMI monitor 将 atomic request、read old value 和 write response 组装成完整
事务。cacheable 普通 AMO 和 LR 与 LOAD 复用同一套旧值预测：request 到达时先从
golden memory 填充 requested byte，全部已知时立即发布 expected；只有仍有未知
byte 时才等待对应 downstream old-value response 补齐。atomic transaction 完成后，
reference model 计算 AMO 结果并更新 golden memory。SC 返回 success/failure 状态，
不使用旧值预测。

reference model 不维护 cache shadow。CMO 不改变 golden byte value；invalidate
只丢弃可能只存在于 cache 中的 byte-valid knowledge，后续 refill 再从 memory
response 学习，这样可以间接检查 CMO 的可见性。flush 类 CMO 不执行任何
golden-memory 操作，因为它不会改变整个 memory 的架构值。

abort request 不更新 reference state。需要 response 时 predictor 立即生成
`aborted=1` 的 expected；`need_rsp=0` 不生成 expected。

predictor 通过 `clone()` 创建每笔 expected；两个 evaluator 在接收事务并入队前
也通过 `clone()` 保存独立副本，避免发布方后续修改事务影响延迟比较。

`hpdcache_cacheable_evaluator` 保留原 evaluator 的 `{SID,TID}` FIFO compare
模式，并增加 abort/error 对比及 uncacheable 路由过滤。cacheable LOAD 和 AMO
只比较 `data_valid=1` 的 byte，STORE/CMO 检查 response 状态。

LR 的 CMI LDEX 完成时建立 8-byte reservation。普通 STORE 或 AMO 命中该地址时
清除 reservation；SC 请求到达 predictor 时立即检查并清除 reservation，并在
expected item 中记录该 SC 是否应产生 CMI STEX。该标记只描述 forwarding 预期，
下游 STEX 仍可能返回 exclusive failure。

## 9. UC/AMO Forwarding Evaluator

`hpdcache_cmi_monitor` 捕获所有 CMI request/response；UC/AMO forwarding evaluator
只接收其中的 uncacheable 普通读写和全部 AMO。write address 与
write data channel 分别排队，按 address 顺序消费 `mem_req_len + 1` 个 data beat，
并检查每拍 `mem_req_w_last`。cacheable burst 也必须完整消费后才能过滤，避免
剩余 beat 与后续 uncacheable request 错配。uncacheable write 必须为单拍，
monitor 按 memory ID 保存 read request 和组装后的 write request，并将 read beat、
write response 合并回 request context。所有 pending request、write channel 暂存
队列和未返回 write response 全部清空时才报告 idle。

monitor 通过三个 typed analysis port 发布 CMI：普通读写分别进入
`read_ap`/`write_ap`，完整 AMO（包括 LR、SC 以及同时具有读写响应的 AMO）进入
`atomic_ap`。后者使用 `hpdcache_cmi_atomic_item`，同时携带 request、old-value
read response、write response 和 STEX exclusive status，避免订阅者再用 `cmd`
区分 AMO。

`hpdcache_uc_amo_forwarding_evaluator` 接收 monitor 已组装的完整 CRI 和 CMI
transaction。它过滤 cacheable 普通 LOAD/STORE，将所有 uncacheable 普通访问和
全部 AMO 分别放入全局 FIFO 后顺序配对。每一对 transaction 检查地址、command、
transfer mask、STORE/AMO operand、response error、LOAD/AMO old value 和 SC status；
`need_rsp=0` 的 CRI transaction 同样参与 request 比较，但不要求 CRI response。
cacheable 普通 response 在完整 CRI transaction 进入 evaluator 时即被过滤，不影响
这条 FIFO 的顺序。

SC 是例外：UC/AMO forwarding evaluator 订阅 predictor 发布的显式 forwarding 预期。
没有有效 reservation 的 SC 必须由 DUT 本地返回 failure，且不得错误消费队首 CMI；
预期 forwarding 的 SC 必须与真实 STEX 配对，再根据 CMI write response 检查最终
success/failure status。evaluator 不再通过 CRI/CMI 队首是否匹配来猜测 SC 路径。

abort 请求不得出现在 CMI；需要 response 的 abort 必须收到 CRI
`aborted=1,error=0`。对于 `need_rsp=0` 的正常 forwarding，CMI response 仍被
消费并计数，但不会等待不存在的 CRI response。

## 10. 结束、检查和统计

base test 是唯一 objection owner。random vseq 及其四个 worker 完成后，test 最多
等待 10 ms，
直到下列状态全部为空：

- active driver 的 request/tag/outstanding 状态；
- sequencer TID mailbox；
- CRI/CMI monitor context；
- predictor pending expected；
- cacheable 与 UC/AMO forwarding evaluator queue。

顶层全局仿真时间保护超时为 100 ms，Python wrapper 另行限制 simulator 的 wall-clock
时间，以覆盖 license、加载和 Tcl 卡死。各 component 在 `check_phase` 报告未配对状态，在
`report_phase` 打印 request、VIPT、abort、response、prediction、compare 和
outstanding 数量。非致命检查统一使用 `HPDCACHE_CHK_*` ID；schema 1 的环境记录
逐字段校验，test-specific stimulus 记录可选。sequence 不维护只包围 `start()`
调用的冗余启动/完成计数。

## 11. 默认随机回归

`hpdcache_random_test` 只配置每个 worker 的 item 数、初始化并启动一个
`hpdcache_random_vseq`。vseq 根据 base vseq 中注入的 CRI sequencer handle 数量创建
worker，每个 worker 一对一使用一个 active CRI sequencer。因此不会假设全部
requester 都 active，也不会把 worker 映射到 passive agent。当前配置产生 4 个
worker，每个 worker 并发启动 1000 个单笔 `hpdcache_random_seq_api`，合计 4000 笔；
requester 0..3 为 active，requester 4 保留给 stride prefetcher。

```sh
export QUESTA_HOME=/path/to/modeltech
make test
```

memory response model 当前采用 in-order、normal response timing、LIGHT 随机
backpressure；普通 read/write、AMO error 和 read-side exclusive-fail injection
关闭，write-side exclusive-fail injection 开启 16 次，用于检查 STEX failure。
build 和 simulation log 位于 `build/questa/`。

`hpdcache_atomic_test` 使用同一套 drain 和 scoreboard 检查，运行命令为：

```sh
make test TEST=hpdcache_atomic_test SEED=1
```

## 12. 尚未覆盖

- IO PMA 访问；
- active stride-prefetch 配置和 checking；
- memory out-of-order/error injection campaign；
- functional coverage、性能采样和项目自有 SVA；Questa code coverage 已由主流程默认收集；
- CVA6 之外的其他 HPDcache 参数组合。
