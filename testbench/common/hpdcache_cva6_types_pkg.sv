// SPDX-License-Identifier: Apache-2.0
package hpdcache_cva6_types_pkg;
  import hpdcache_pkg::*;
  import hpdcache_cva6_config_pkg::*;
  `include "hpdcache_typedef.svh"

  localparam hpdcache_user_cfg_t HPDCACHE_USER_CFG = '{
    nRequesters              : NREQUESTERS,
    paWidth                  : PA_WIDTH,
    wordWidth                : WORD_WIDTH,
    sets                     : SETS,
    ways                     : WAYS,
    clWords                  : CL_WORDS,
    reqWords                 : REQ_WORDS,
    reqTransIdWidth          : REQ_TRANS_ID_WIDTH,
    reqSrcIdWidth            : REQ_SRC_ID_WIDTH,
    victimSel                : HPDCACHE_VICTIM_RANDOM,
    dataWaysPerRamWord       : DATA_WAYS_PER_RAM_WORD,
    dataSetsPerRam           : DATA_SETS_PER_RAM,
    dataRamByteEnable        : DATA_RAM_BYTE_ENABLE,
    accessWords              : ACCESS_WORDS,
    mshrSets                 : MSHR_SETS,
    mshrWays                 : MSHR_WAYS,
    mshrWaysPerRamWord       : MSHR_WAYS_PER_RAM_WORD,
    mshrSetsPerRam           : MSHR_SETS_PER_RAM,
    mshrRamByteEnable        : MSHR_RAM_BYTE_ENABLE,
    mshrUseRegbank           : MSHR_USE_REGBANK,
    cbufEntries              : CBUF_ENTRIES,
    refillCoreRspFeedthrough : REFILL_CORE_RSP_FEEDTHROUGH,
    refillFifoDepth          : REFILL_FIFO_DEPTH,
    wbufDirEntries           : WBUF_DIR_ENTRIES,
    wbufDataEntries          : WBUF_DATA_ENTRIES,
    wbufWords                : WBUF_WORDS,
    wbufTimecntWidth         : WBUF_TIMECNT_WIDTH,
    rtabEntries              : RTAB_ENTRIES,
    flushEntries             : FLUSH_ENTRIES,
    flushFifoDepth           : FLUSH_FIFO_DEPTH,
    memAddrWidth             : MEM_ADDR_WIDTH,
    memIdWidth               : MEM_ID_WIDTH,
    memDataWidth             : MEM_DATA_WIDTH,
    wtEn                     : WT_ENABLE,
    wbEn                     : WB_ENABLE,
    lowLatency               : LOW_LATENCY,
    eccEn                    : ECC_ENABLE,
    eccScrubberEn            : ECC_SCRUBBER_ENABLE
  };

  localparam hpdcache_cfg_t HPDCACHE_CFG = hpdcacheBuildConfig(HPDCACHE_USER_CFG);

  typedef logic [HPDCACHE_CFG.u.wbufTimecntWidth-1:0] wbuf_timecnt_t;

  `HPDCACHE_TYPEDEF_REQ_ATTR_T(
    hpdcache_req_offset_t,
    hpdcache_data_word_t,
    hpdcache_data_be_t,
    hpdcache_req_data_t,
    hpdcache_req_be_t,
    hpdcache_req_sid_t,
    hpdcache_req_tid_t,
    hpdcache_tag_t,
    HPDCACHE_CFG
  );
  `HPDCACHE_TYPEDEF_REQ_T(
    hpdcache_req_t,
    hpdcache_req_offset_t,
    hpdcache_req_data_t,
    hpdcache_req_be_t,
    hpdcache_req_sid_t,
    hpdcache_req_tid_t,
    hpdcache_tag_t
  );
  `HPDCACHE_TYPEDEF_RSP_T(
    hpdcache_rsp_t,
    hpdcache_req_data_t,
    hpdcache_req_sid_t,
    hpdcache_req_tid_t
  );

  typedef logic [HPDCACHE_CFG.u.paWidth-1:0] hpdcache_req_addr_t;
  typedef logic [HPDCACHE_CFG.nlineWidth-1:0] hpdcache_nline_t;

  `HPDCACHE_TYPEDEF_MEM_ATTR_T(
    hpdcache_mem_addr_t,
    hpdcache_mem_id_t,
    hpdcache_mem_data_t,
    hpdcache_mem_be_t,
    HPDCACHE_CFG
  );
  `HPDCACHE_TYPEDEF_MEM_REQ_T(
    hpdcache_mem_req_t,
    hpdcache_mem_addr_t,
    hpdcache_mem_id_t
  );
  `HPDCACHE_TYPEDEF_MEM_RESP_R_T(
    hpdcache_mem_resp_r_t,
    hpdcache_mem_id_t,
    hpdcache_mem_data_t
  );
  `HPDCACHE_TYPEDEF_MEM_REQ_W_T(
    hpdcache_mem_req_w_t,
    hpdcache_mem_data_t,
    hpdcache_mem_be_t
  );
  `HPDCACHE_TYPEDEF_MEM_RESP_W_T(
    hpdcache_mem_resp_w_t,
    hpdcache_mem_id_t
  );

  function automatic hpdcache_req_addr_t request_address(hpdcache_req_t req);
    return {req.addr_tag, req.addr_offset};
  endfunction

  function automatic hpdcache_tag_t address_tag(hpdcache_req_addr_t addr);
    return addr[HPDCACHE_CFG.reqOffsetWidth +: HPDCACHE_CFG.tagWidth];
  endfunction

  function automatic hpdcache_req_offset_t address_offset(hpdcache_req_addr_t addr);
    return addr[HPDCACHE_CFG.reqOffsetWidth-1:0];
  endfunction
endpackage
