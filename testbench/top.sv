// SPDX-License-Identifier: Apache-2.0
module top;
  timeunit 1ns;
  timeprecision 1ps;

  import uvm_pkg::*;
  import hpdcache_pkg::*;
  import hwpf_stride_pkg::*;
  import `HPDCACHE_CONFIG_PKG::*;
  import hpdcache_cva6_types_pkg::*;
  import hpdcache_uvm_components_pkg::*;
  import clock_driver_pkg::*;
  import reset_driver_pkg::*;
  import memory_rsp_model_pkg::*;
  import axi2mem_pkg::*;

  localparam int unsigned NUM_CORE_REQUESTERS =
    NREQUESTERS - (HAS_PREFETCHER ? 1 : 0);
  localparam int unsigned PREFETCH_REQUESTER = NREQUESTERS - 1;
  localparam int unsigned NUM_HW_PREFETCH = 4;

  logic clk;
  logic rst_n;

  xrtl_clock_vif clock_if(.clock(clk));
  xrtl_reset_vif #(1'b1, 8, 0) reset_if(
    .clk                (clk),
    .reset              (),
    .reset_n            (rst_n),
    .post_shutdown_phase()
  );

  logic          core_req_valid[NREQUESTERS];
  logic          core_req_ready[NREQUESTERS];
  hpdcache_req_t core_req[NREQUESTERS];
  logic          core_req_abort[NREQUESTERS];
  hpdcache_tag_t core_req_tag[NREQUESTERS];
  hpdcache_pma_t core_req_pma[NREQUESTERS];
  logic          core_rsp_valid[NREQUESTERS];
  hpdcache_rsp_t core_rsp[NREQUESTERS];

  hpdcache_cri_if cri_if[NREQUESTERS](.clk_i(clk), .rst_ni(rst_n));

  for (genvar requester = 0; requester < NREQUESTERS; requester++) begin : gen_requester_monitors
    assign cri_if[requester].req_ready = core_req_ready[requester];
    assign cri_if[requester].req_valid = core_req_valid[requester];
    assign cri_if[requester].req       = core_req[requester];
    assign cri_if[requester].req_abort = core_req_abort[requester];
    assign cri_if[requester].req_tag   = core_req_tag[requester];
    assign cri_if[requester].req_pma   = core_req_pma[requester];
    assign cri_if[requester].rsp_valid = core_rsp_valid[requester];
    assign cri_if[requester].rsp       = core_rsp[requester];

    initial begin
      uvm_config_db#(virtual hpdcache_cri_if)::set(
        null,
        $sformatf("uvm_test_top.env.cri_agent_%0d.*", requester),
        "vif",
        cri_if[requester]
      );
    end
  end

  logic          prefetch_req_valid;
  logic          prefetch_req_ready;
  hpdcache_req_t prefetch_req;
  logic          prefetch_req_abort;
  hpdcache_tag_t prefetch_req_tag;
  hpdcache_pma_t prefetch_req_pma;
  logic          prefetch_rsp_valid;
  hpdcache_rsp_t prefetch_rsp;

  for (genvar requester = 0; requester < NUM_CORE_REQUESTERS; requester++) begin : gen_core_drivers
    assign core_req_valid[requester] = cri_if[requester].drv_req_valid;
    assign core_req[requester]       = cri_if[requester].drv_req;
    assign core_req_abort[requester] = cri_if[requester].drv_req_abort;
    assign core_req_tag[requester]   = cri_if[requester].drv_req_tag;
    assign core_req_pma[requester]   = cri_if[requester].drv_req_pma;
  end

  // --------------------------------------------------------------------------
  // CVA6 stride prefetcher: fully connected, but disabled by zeroed CSRs.
  // It snoops the four core requester ports and owns requester four.
  // --------------------------------------------------------------------------
  logic                  [NUM_HW_PREFETCH-1:0] hwpf_base_set;
  hwpf_stride_base_t     [NUM_HW_PREFETCH-1:0] hwpf_base_i;
  hwpf_stride_base_t     [NUM_HW_PREFETCH-1:0] hwpf_base_o;
  logic                  [NUM_HW_PREFETCH-1:0] hwpf_param_set;
  hwpf_stride_param_t    [NUM_HW_PREFETCH-1:0] hwpf_param_i;
  hwpf_stride_param_t    [NUM_HW_PREFETCH-1:0] hwpf_param_o;
  logic                  [NUM_HW_PREFETCH-1:0] hwpf_throttle_set;
  hwpf_stride_throttle_t [NUM_HW_PREFETCH-1:0] hwpf_throttle_i;
  hwpf_stride_throttle_t [NUM_HW_PREFETCH-1:0] hwpf_throttle_o;
  hwpf_stride_status_t                         hwpf_status;

  logic                  [NUM_CORE_REQUESTERS-1:0] snoop_valid;
  logic                  [NUM_CORE_REQUESTERS-1:0] snoop_abort;
  hpdcache_req_offset_t  [NUM_CORE_REQUESTERS-1:0] snoop_offset;
  hpdcache_tag_t         [NUM_CORE_REQUESTERS-1:0] snoop_tag;
  logic                  [NUM_CORE_REQUESTERS-1:0] snoop_phys_indexed;

  assign hwpf_base_set     = '0;
  assign hwpf_base_i       = '0;
  assign hwpf_param_set    = '0;
  assign hwpf_param_i      = '0;
  assign hwpf_throttle_set = '0;
  assign hwpf_throttle_i   = '0;

  for (genvar snoop = 0; snoop < NUM_CORE_REQUESTERS; snoop++) begin : gen_snoop
    assign snoop_valid[snoop] = cri_if[snoop].req_valid &&
                                cri_if[snoop].req_ready;
    assign snoop_abort[snoop] = cri_if[snoop].req_abort;
    assign snoop_offset[snoop] = cri_if[snoop].req.addr_offset;
    assign snoop_tag[snoop] = cri_if[snoop].req.phys_indexed ?
                              cri_if[snoop].req.addr_tag :
                              cri_if[snoop].req_tag;
    assign snoop_phys_indexed[snoop] = cri_if[snoop].req.phys_indexed;
  end

  if (HAS_PREFETCHER) begin : gen_prefetcher
    assign core_req_valid[PREFETCH_REQUESTER] = prefetch_req_valid;
    assign prefetch_req_ready                 = core_req_ready[PREFETCH_REQUESTER];
    assign core_req[PREFETCH_REQUESTER]       = prefetch_req;
    assign core_req_abort[PREFETCH_REQUESTER] = prefetch_req_abort;
    assign core_req_tag[PREFETCH_REQUESTER]   = prefetch_req_tag;
    assign core_req_pma[PREFETCH_REQUESTER]   = prefetch_req_pma;
    assign prefetch_rsp_valid                 = core_rsp_valid[PREFETCH_REQUESTER];
    assign prefetch_rsp                       = core_rsp[PREFETCH_REQUESTER];

    hwpf_stride_wrapper #(
      .HPDcacheCfg          (HPDCACHE_CFG),
      .NUM_HW_PREFETCH      (NUM_HW_PREFETCH),
      .NUM_SNOOP_PORTS      (NUM_CORE_REQUESTERS),
      .hpdcache_tag_t       (hpdcache_tag_t),
      .hpdcache_req_offset_t(hpdcache_req_offset_t),
      .hpdcache_req_data_t  (hpdcache_req_data_t),
      .hpdcache_req_be_t    (hpdcache_req_be_t),
      .hpdcache_req_sid_t   (hpdcache_req_sid_t),
      .hpdcache_req_tid_t   (hpdcache_req_tid_t),
      .hpdcache_req_t       (hpdcache_req_t),
      .hpdcache_rsp_t       (hpdcache_rsp_t)
    ) prefetcher (
      .clk_i                     (clk),
      .rst_ni                    (rst_n),
      .hwpf_stride_base_set_i    (hwpf_base_set),
      .hwpf_stride_base_i        (hwpf_base_i),
      .hwpf_stride_base_o        (hwpf_base_o),
      .hwpf_stride_param_set_i   (hwpf_param_set),
      .hwpf_stride_param_i       (hwpf_param_i),
      .hwpf_stride_param_o       (hwpf_param_o),
      .hwpf_stride_throttle_set_i(hwpf_throttle_set),
      .hwpf_stride_throttle_i    (hwpf_throttle_i),
      .hwpf_stride_throttle_o    (hwpf_throttle_o),
      .hwpf_stride_status_o      (hwpf_status),
      .snoop_valid_i             (snoop_valid),
      .snoop_abort_i             (snoop_abort),
      .snoop_addr_offset_i       (snoop_offset),
      .snoop_addr_tag_i          (snoop_tag),
      .snoop_phys_indexed_i      (snoop_phys_indexed),
      .hpdcache_req_sid_i        (hpdcache_req_sid_t'(PREFETCH_REQUESTER)),
      .hpdcache_req_valid_o      (prefetch_req_valid),
      .hpdcache_req_ready_i      (prefetch_req_ready),
      .hpdcache_req_o            (prefetch_req),
      .hpdcache_req_abort_o      (prefetch_req_abort),
      .hpdcache_req_tag_o        (prefetch_req_tag),
      .hpdcache_req_pma_o        (prefetch_req_pma),
      .hpdcache_rsp_valid_i      (prefetch_rsp_valid),
      .hpdcache_rsp_i            (prefetch_rsp)
    );
  end

  // --------------------------------------------------------------------------
  // DUT native memory channels and the thin AXI mapping used by cv_dv_utils.
  // --------------------------------------------------------------------------
  logic                   mem_req_read_ready;
  logic                   mem_req_read_valid;
  hpdcache_mem_req_t      mem_req_read;
  logic                   mem_rsp_read_ready;
  logic                   mem_rsp_read_valid;
  hpdcache_mem_resp_r_t   mem_rsp_read;
  logic                   mem_req_write_ready;
  logic                   mem_req_write_valid;
  hpdcache_mem_req_t      mem_req_write;
  logic                   mem_req_write_data_ready;
  logic                   mem_req_write_data_valid;
  hpdcache_mem_req_w_t    mem_req_write_data;
  logic                   mem_rsp_write_ready;
  logic                   mem_rsp_write_valid;
  hpdcache_mem_resp_w_t   mem_rsp_write;

  hpdcache_cmi_if cmi_if(.clk_i(clk), .rst_ni(rst_n));

  assign cmi_if.mem_req_read_ready       = mem_req_read_ready;
  assign cmi_if.mem_req_read_valid       = mem_req_read_valid;
  assign cmi_if.mem_req_read             = mem_req_read;
  assign cmi_if.mem_rsp_read_ready       = mem_rsp_read_ready;
  assign cmi_if.mem_rsp_read_valid       = mem_rsp_read_valid;
  assign cmi_if.mem_rsp_read             = mem_rsp_read;
  assign cmi_if.mem_req_write_ready      = mem_req_write_ready;
  assign cmi_if.mem_req_write_valid      = mem_req_write_valid;
  assign cmi_if.mem_req_write            = mem_req_write;
  assign cmi_if.mem_req_write_data_ready = mem_req_write_data_ready;
  assign cmi_if.mem_req_write_data_valid = mem_req_write_data_valid;
  assign cmi_if.mem_req_write_data       = mem_req_write_data;
  assign cmi_if.mem_rsp_write_ready      = mem_rsp_write_ready;
  assign cmi_if.mem_rsp_write_valid      = mem_rsp_write_valid;
  assign cmi_if.mem_rsp_write            = mem_rsp_write;

  axi_if #(
    .wd_addr(MEM_ADDR_WIDTH),
    .wd_data(MEM_DATA_WIDTH),
    .wd_id  (MEM_ID_WIDTH),
    .wd_user(1)
  ) axi_vif(.clk(clk), .rstn(rst_n));

  memory_response_if #(
    .addr_width(MEM_ADDR_WIDTH),
    .data_width(MEM_DATA_WIDTH),
    .id_width  (MEM_ID_WIDTH)
  ) mem_rsp_vif(.clk(clk), .rstn(rst_n));

  memory_response_if #(
    .addr_width(MEM_ADDR_WIDTH),
    .data_width(MEM_DATA_WIDTH),
    .id_width  (MEM_ID_WIDTH)
  ) mem_rd_vif(.clk(clk), .rstn(rst_n));

  memory_response_if #(
    .addr_width(MEM_ADDR_WIDTH),
    .data_width(MEM_DATA_WIDTH),
    .id_width  (MEM_ID_WIDTH)
  ) mem_wr_vif(.clk(clk), .rstn(rst_n));

  assign axi_vif.ar_ready = 1'b1;
  assign axi_vif.aw_ready = 1'b1;
  assign axi_vif.w_ready  = 1'b1;

  assign mem_req_read_ready = axi_vif.ar_ready;
  assign axi_vif.ar_valid  = mem_req_read_valid;
  assign axi_vif.ar_addr   = mem_req_read.mem_req_addr;
  assign axi_vif.ar_len    = mem_req_read.mem_req_len;
  assign axi_vif.ar_size   = mem_req_read.mem_req_size;
  assign axi_vif.ar_id     = mem_req_read.mem_req_id;
  assign axi_vif.ar_burst  = BURST_INCR;
  assign axi_vif.ar_lock   = (mem_req_read.mem_req_command == HPDCACHE_MEM_ATOMIC) &&
                             (mem_req_read.mem_req_atomic == HPDCACHE_MEM_ATOMIC_LDEX);
  assign axi_vif.ar_cache  = CACHE_BUFFERABLE;
  assign axi_vif.ar_prot   = '0;
  assign axi_vif.ar_qos    = '0;
  assign axi_vif.ar_region = '0;
  assign axi_vif.ar_user   = mem_req_read.mem_req_cacheable;

  assign mem_rsp_read_valid = axi_vif.r_valid;
  assign axi_vif.r_ready    = mem_rsp_read_ready;
  always_comb begin
    mem_rsp_read.mem_resp_r_data  = axi_vif.r_data;
    mem_rsp_read.mem_resp_r_last  = axi_vif.r_last;
    mem_rsp_read.mem_resp_r_id    = axi_vif.r_id;
    mem_rsp_read.mem_resp_r_error = (axi_vif.r_resp inside {RESP_OKAY, RESP_EXOKAY}) ?
                                     HPDCACHE_MEM_RESP_OK : HPDCACHE_MEM_RESP_NOK;
  end

  assign mem_req_write_ready = axi_vif.aw_ready;
  assign axi_vif.aw_valid  = mem_req_write_valid;
  assign axi_vif.aw_addr   = mem_req_write.mem_req_addr;
  assign axi_vif.aw_len    = mem_req_write.mem_req_len;
  assign axi_vif.aw_size   = mem_req_write.mem_req_size;
  assign axi_vif.aw_id     = mem_req_write.mem_req_id;
  assign axi_vif.aw_burst  = BURST_INCR;
  assign axi_vif.aw_cache  = CACHE_BUFFERABLE;
  assign axi_vif.aw_prot   = '0;
  assign axi_vif.aw_qos    = '0;
  assign axi_vif.aw_region = '0;
  assign axi_vif.aw_user   = mem_req_write.mem_req_cacheable;
  assign axi_vif.aw_lock   = (mem_req_write.mem_req_command == HPDCACHE_MEM_ATOMIC) &&
                             (mem_req_write.mem_req_atomic == HPDCACHE_MEM_ATOMIC_STEX);
  always_comb begin
    axi_vif.aw_atop = '0;
    if (mem_req_write.mem_req_command == HPDCACHE_MEM_ATOMIC) begin
      case (mem_req_write.mem_req_atomic)
        HPDCACHE_MEM_ATOMIC_ADD:  axi_vif.aw_atop = {AXI_ATOMIC_LOAD, 1'b0,
                                                      AXI_ATOMIC_ADD};
        HPDCACHE_MEM_ATOMIC_CLR:  axi_vif.aw_atop = {AXI_ATOMIC_LOAD, 1'b0,
                                                      AXI_ATOMIC_CLR};
        HPDCACHE_MEM_ATOMIC_SET:  axi_vif.aw_atop = {AXI_ATOMIC_LOAD, 1'b0,
                                                      AXI_ATOMIC_SET};
        HPDCACHE_MEM_ATOMIC_EOR:  axi_vif.aw_atop = {AXI_ATOMIC_LOAD, 1'b0,
                                                      AXI_ATOMIC_EOR};
        HPDCACHE_MEM_ATOMIC_SMAX: axi_vif.aw_atop = {AXI_ATOMIC_LOAD, 1'b0,
                                                      AXI_ATOMIC_SMAX};
        HPDCACHE_MEM_ATOMIC_SMIN: axi_vif.aw_atop = {AXI_ATOMIC_LOAD, 1'b0,
                                                      AXI_ATOMIC_SMIN};
        HPDCACHE_MEM_ATOMIC_UMAX: axi_vif.aw_atop = {AXI_ATOMIC_LOAD, 1'b0,
                                                      AXI_ATOMIC_UMAX};
        HPDCACHE_MEM_ATOMIC_UMIN: axi_vif.aw_atop = {AXI_ATOMIC_LOAD, 1'b0,
                                                      AXI_ATOMIC_UMIN};
        HPDCACHE_MEM_ATOMIC_SWAP: axi_vif.aw_atop = {AXI_ATOMIC_OTHERS, 4'b0000};
        default:                  axi_vif.aw_atop = '0;
      endcase
    end
  end

  assign mem_req_write_data_ready = axi_vif.w_ready;
  assign axi_vif.w_valid = mem_req_write_data_valid;
  assign axi_vif.w_data  = mem_req_write_data.mem_req_w_data;
  assign axi_vif.w_strb  = mem_req_write_data.mem_req_w_be;
  assign axi_vif.w_last  = mem_req_write_data.mem_req_w_last;
  assign axi_vif.w_user  = 1'b0;

  assign mem_rsp_write_valid = axi_vif.b_valid;
  assign axi_vif.b_ready      = mem_rsp_write_ready;
  always_comb begin
    mem_rsp_write.mem_resp_w_id = axi_vif.b_id;
    mem_rsp_write.mem_resp_w_error = (axi_vif.b_resp inside {RESP_OKAY, RESP_EXOKAY}) ?
                                      HPDCACHE_MEM_RESP_OK : HPDCACHE_MEM_RESP_NOK;
    mem_rsp_write.mem_resp_w_is_atomic = (axi_vif.b_resp == RESP_EXOKAY);
  end

  hpdcache #(
    .HPDcacheCfg          (HPDCACHE_CFG),
    .wbuf_timecnt_t       (wbuf_timecnt_t),
    .hpdcache_tag_t       (hpdcache_tag_t),
    .hpdcache_data_word_t (hpdcache_data_word_t),
    .hpdcache_data_be_t   (hpdcache_data_be_t),
    .hpdcache_req_offset_t(hpdcache_req_offset_t),
    .hpdcache_req_data_t  (hpdcache_req_data_t),
    .hpdcache_req_be_t    (hpdcache_req_be_t),
    .hpdcache_req_sid_t   (hpdcache_req_sid_t),
    .hpdcache_req_tid_t   (hpdcache_req_tid_t),
    .hpdcache_req_t       (hpdcache_req_t),
    .hpdcache_rsp_t       (hpdcache_rsp_t),
    .hpdcache_mem_addr_t  (hpdcache_mem_addr_t),
    .hpdcache_mem_id_t    (hpdcache_mem_id_t),
    .hpdcache_mem_data_t  (hpdcache_mem_data_t),
    .hpdcache_mem_be_t    (hpdcache_mem_be_t),
    .hpdcache_mem_req_t   (hpdcache_mem_req_t),
    .hpdcache_mem_req_w_t (hpdcache_mem_req_w_t),
    .hpdcache_mem_resp_r_t(hpdcache_mem_resp_r_t),
    .hpdcache_mem_resp_w_t(hpdcache_mem_resp_w_t)
  ) dut (
    .clk_i                            (clk),
    .rst_ni                           (rst_n),
    .wbuf_flush_i                     (1'b0),
    .core_req_valid_i                 (core_req_valid),
    .core_req_ready_o                 (core_req_ready),
    .core_req_i                       (core_req),
    .core_req_abort_i                 (core_req_abort),
    .core_req_tag_i                   (core_req_tag),
    .core_req_pma_i                   (core_req_pma),
    .core_rsp_valid_o                 (core_rsp_valid),
    .core_rsp_o                       (core_rsp),
    .mem_req_read_ready_i             (mem_req_read_ready),
    .mem_req_read_valid_o             (mem_req_read_valid),
    .mem_req_read_o                   (mem_req_read),
    .mem_resp_read_ready_o            (mem_rsp_read_ready),
    .mem_resp_read_valid_i            (mem_rsp_read_valid),
    .mem_resp_read_i                  (mem_rsp_read),
    .mem_resp_read_inval_i            (1'b0),
    .mem_resp_read_inval_nline_i      ('0),
    .mem_req_write_ready_i            (mem_req_write_ready),
    .mem_req_write_valid_o            (mem_req_write_valid),
    .mem_req_write_o                  (mem_req_write),
    .mem_req_write_data_ready_i       (mem_req_write_data_ready),
    .mem_req_write_data_valid_o       (mem_req_write_data_valid),
    .mem_req_write_data_o             (mem_req_write_data),
    .mem_resp_write_ready_o           (mem_rsp_write_ready),
    .mem_resp_write_valid_i           (mem_rsp_write_valid),
    .mem_resp_write_i                 (mem_rsp_write),
    .evt_cache_write_miss_o           (),
    .evt_cache_read_miss_o            (),
    .evt_cache_dir_unc_err_o          (),
    .evt_cache_dir_cor_err_o          (),
    .evt_cache_dat_unc_err_o          (),
    .evt_cache_dat_cor_err_o          (),
    .evt_scrub_complete_o             (),
    .evt_uncached_req_o               (),
    .evt_cmo_req_o                    (),
    .evt_write_req_o                  (),
    .evt_read_req_o                   (),
    .evt_prefetch_req_o               (),
    .evt_req_on_hold_o                (),
    .evt_rtab_rollback_o              (),
    .evt_stall_refill_o               (),
    .evt_stall_o                      (),
    .wbuf_empty_o                     (),
    .cfg_enable_i                     (1'b1),
    .cfg_wbuf_threshold_i             (wbuf_timecnt_t'(3)),
    .cfg_wbuf_reset_timecnt_on_write_i(1'b1),
    .cfg_wbuf_sequential_waw_i        (1'b0),
    .cfg_wbuf_inhibit_write_coalescing_i(1'b0),
    .cfg_prefetch_updt_plru_i         (1'b0),
    .cfg_error_on_cacheable_amo_i     (1'b0),
    .cfg_rtab_single_entry_i          (1'b0),
    .cfg_default_wb_i                 (1'b1),
    .cfg_scrub_enable_i               (1'b0),
    .cfg_scrub_period_i               ('0),
    .cfg_scrub_restart_i              (1'b0)
  );

  // --------------------------------------------------------------------------
  // cv_dv_utils has separate read/write request interfaces.  Arbitrate them
  // onto one memory_response_model instance so both share the same memory.
  // --------------------------------------------------------------------------
  typedef struct packed {
    logic                    valid;
    logic [MEM_ADDR_WIDTH-1:0] addr;
    logic                    wrn;
    logic [MEM_ID_WIDTH-1:0] id;
    logic [MEM_ID_WIDTH-1:0] src_id;
    logic [MEM_DATA_WIDTH-1:0] data;
    logic [MEM_DATA_WIDTH/8-1:0] strb;
    logic                    amo;
    mem_atomic_t             amo_op;
  } memory_request_t;

  memory_request_t [1:0] memory_requests;
  memory_request_t selected_memory_request;
  logic [1:0] memory_request_valid;
  logic [1:0] memory_request_grant;

  always_comb begin
    memory_requests[0] = '{valid: mem_rd_vif.req_valid,
                           addr: mem_rd_vif.req_addr,
                           wrn: mem_rd_vif.req_wrn,
                           id: mem_rd_vif.req_id,
                           src_id: mem_rd_vif.src_id,
                           data: mem_rd_vif.req_data,
                           strb: mem_rd_vif.req_strb,
                           amo: mem_rd_vif.req_amo,
                           amo_op: mem_rd_vif.amo_op};
    memory_requests[1] = '{valid: mem_wr_vif.req_valid,
                           addr: mem_wr_vif.req_addr,
                           wrn: mem_wr_vif.req_wrn,
                           id: mem_wr_vif.req_id,
                           src_id: mem_wr_vif.src_id,
                           data: mem_wr_vif.req_data,
                           strb: mem_wr_vif.req_strb,
                           amo: mem_wr_vif.req_amo,
                           amo_op: mem_wr_vif.amo_op};
  end

  assign memory_request_valid = {mem_wr_vif.req_valid, mem_rd_vif.req_valid};
  assign mem_rd_vif.req_ready = memory_request_grant[0] && mem_rsp_vif.req_ready;
  assign mem_wr_vif.req_ready = memory_request_grant[1] && mem_rsp_vif.req_ready;

  hpdcache_rrarb #(.N(2)) memory_request_arbiter (
    .clk_i  (clk),
    .rst_ni (rst_n),
    .req_i  (memory_request_valid),
    .gnt_o  (memory_request_grant),
    .ready_i(mem_rsp_vif.req_ready)
  );

  hpdcache_mux #(
    .NINPUT     (2),
    .DATA_WIDTH ($bits(memory_request_t)),
    .ONE_HOT_SEL(1'b1)
  ) memory_request_mux (
    .data_i(memory_requests),
    .sel_i (memory_request_grant),
    .data_o(selected_memory_request)
  );

  always_comb begin
    mem_rsp_vif.req_valid = selected_memory_request.valid;
    mem_rsp_vif.req_addr  = selected_memory_request.addr;
    mem_rsp_vif.req_wrn   = selected_memory_request.wrn;
    mem_rsp_vif.req_id    = selected_memory_request.id;
    mem_rsp_vif.src_id    = selected_memory_request.src_id;
    mem_rsp_vif.req_data  = selected_memory_request.data;
    mem_rsp_vif.req_strb  = selected_memory_request.strb;
    mem_rsp_vif.req_amo   = selected_memory_request.amo;
    mem_rsp_vif.amo_op    = selected_memory_request.amo_op;
    mem_rsp_vif.req_ready = mem_rsp_vif.req_ready_bp;
  end

  assign mem_rsp_vif.rd_res_ready = 1'b1;
  assign mem_rsp_vif.wr_res_ready = 1'b1;
  assign mem_rd_vif.rd_res_valid = mem_rsp_vif.rd_res_valid;
  assign mem_rd_vif.rd_res_data = mem_rsp_vif.rd_res_data;
  assign mem_rd_vif.rd_res_id = mem_rsp_vif.rd_res_id;
  assign mem_rd_vif.rd_res_err = mem_rsp_vif.rd_res_err;
  assign mem_rd_vif.rd_res_addr = mem_rsp_vif.rd_res_addr;
  assign mem_rd_vif.rd_res_ex_fail = mem_rsp_vif.rd_res_ex_fail;
  assign mem_rd_vif.wr_res_valid = 1'b0;
  assign mem_wr_vif.wr_res_valid = mem_rsp_vif.wr_res_valid;
  assign mem_wr_vif.wr_res_id = mem_rsp_vif.wr_res_id;
  assign mem_wr_vif.wr_res_err = mem_rsp_vif.wr_res_err;
  assign mem_wr_vif.wr_res_addr = mem_rsp_vif.wr_res_addr;
  assign mem_wr_vif.wr_res_ex_fail = mem_rsp_vif.wr_res_ex_fail;
  assign mem_wr_vif.rd_res_valid = 1'b0;
  assign mem_rd_vif.rd_res_ready = 1'b1;
  assign mem_wr_vif.wr_res_ready = 1'b1;

  initial begin
    uvm_config_db#(virtual xrtl_clock_vif)::set(
      null, "*", "clock_driver", clock_if
    );
    uvm_config_db#(virtual xrtl_reset_vif#(1'b1, 8, 0))::set(
      null, "*", "hpdcache_reset_driver", reset_if
    );
    uvm_config_db#(virtual memory_response_if#(
      MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH
    ))::set(null, "*", "mem_rsp_model", mem_rsp_vif);
    uvm_config_db#(virtual axi_if#(
      MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH, 1
    ))::set(null, "*", "axi2mem_req", axi_vif);
    uvm_config_db#(virtual memory_response_if#(
      MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH
    ))::set(null, "*", "axi2mem_req_rd", mem_rd_vif);
    uvm_config_db#(virtual memory_response_if#(
      MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH
    ))::set(null, "*", "axi2mem_req_wr", mem_wr_vif);
    uvm_config_db#(virtual hpdcache_cmi_if)::set(
      null, "uvm_test_top.env.cmi_agent.*", "vif", cmi_if
    );
    run_test("hpdcache_random_test");
  end

  initial begin
    // Random response backpressure can stretch a 4000-request run beyond
    // several milliseconds.  Keep a generous simulation-time guard so the
    // watchdog catches a real hang without truncating valid regressions.
    #100ms;
    $fatal(1, "global random-test timeout");
  end

endmodule
