`uvm_analysis_imp_decl(_uc_cri_item)
`uvm_analysis_imp_decl(_uc_cmi_read_item)
`uvm_analysis_imp_decl(_uc_cmi_write_item)

class hpdcache_uncacheable_evaluator extends uvm_component;
  `uvm_component_utils(hpdcache_uncacheable_evaluator)

  uvm_analysis_imp_uc_cri_item #(
    hpdcache_cri_item, hpdcache_uncacheable_evaluator
  ) cri_item_imp;
  uvm_analysis_imp_uc_cmi_read_item #(
    hpdcache_cmi_read_item, hpdcache_uncacheable_evaluator
  ) cmi_read_item_imp;
  uvm_analysis_imp_uc_cmi_write_item #(
    hpdcache_cmi_write_item, hpdcache_uncacheable_evaluator
  ) cmi_write_item_imp;

  hpdcache_pma_config pma_cfg;
  protected hpdcache_cri_item cri_transaction_q[$];
  protected hpdcache_cmi_item cmi_transaction_q[$];

  protected int unsigned received_cri_requests;
  protected int unsigned received_cmi_requests;
  protected int unsigned received_cri_responses;
  protected int unsigned received_cmi_responses;
  protected int unsigned compared_requests;
  protected int unsigned compared_responses;
  protected int unsigned order_mismatches;
  protected int unsigned checked_aborts;
  protected int unsigned no_response_transactions;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cri_item_imp = new("cri_item_imp", this);
    cmi_read_item_imp = new("cmi_read_item_imp", this);
    cmi_write_item_imp = new("cmi_write_item_imp", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(hpdcache_pma_config)::get(
          this, "", "pma_cfg", pma_cfg) || pma_cfg == null)
      `uvm_fatal(get_type_name(), "hpdcache_pma_config was not configured")
  endfunction

  function automatic bit is_forwarded_operation(hpdcache_req_op_t op);
    return op inside {HPDCACHE_REQ_LOAD, HPDCACHE_REQ_STORE};
  endfunction

  protected function hpdcache_cri_item clone_cri(hpdcache_cri_item t);
    hpdcache_cri_item snapshot;
    if (!$cast(snapshot, t.clone()))
      `uvm_fatal(get_type_name(), "failed to clone CRI transaction")
    return snapshot;
  endfunction

  protected function hpdcache_cmi_item clone_cmi(hpdcache_cmi_item t);
    hpdcache_cmi_item snapshot;
    if (!$cast(snapshot, t.clone()))
      `uvm_fatal(get_type_name(), "failed to clone CMI transaction")
    return snapshot;
  endfunction

  protected function void enqueue_cri(hpdcache_cri_item t);
    hpdcache_cri_item snapshot;
    snapshot = clone_cri(t);
    cri_transaction_q.push_back(snapshot);
    compare_transactions();
  endfunction

  function void write_uc_cri_item(hpdcache_cri_item t);
    if (!is_forwarded_operation(t.op) || !pma_cfg.is_uncacheable(t.addr))
      return;

    received_cri_requests++;
    if (t.need_rsp)
      received_cri_responses++;
    if (t.pma.uncacheable !== 1'b1)
      `uvm_error("HPDCACHE_CHK_UNCACHEABLE", $sformatf(
        "PMA marks address 0x%0h uncacheable but CRI did not", t.addr))

    if (t.abort) begin
      checked_aborts++;
      if (t.need_rsp && (t.aborted !== 1'b1 || t.error !== 1'b0))
        `uvm_error("HPDCACHE_CHK_ABORT", $sformatf(
          "aborted CRI SID %0d TID %0d aborted=%0b error=%0b",
          t.sid, t.tid, t.aborted, t.error))
      return;
    end
    enqueue_cri(t);
  endfunction

  protected function void enqueue_cmi(hpdcache_cmi_item t);
    hpdcache_cmi_item snapshot;
    if (!t.request_valid || t.request_cacheable || t.cmd == MEM_ATOMIC)
      return;
    received_cmi_requests++;
    if (t.response_valid)
      received_cmi_responses++;
    snapshot = clone_cmi(t);
    cmi_transaction_q.push_back(snapshot);
    compare_transactions();
  endfunction

  function void write_uc_cmi_read_item(hpdcache_cmi_read_item t);
    enqueue_cmi(t);
  endfunction

  function void write_uc_cmi_write_item(hpdcache_cmi_write_item t);
    enqueue_cmi(t);
  endfunction

  protected function void compare_transactions();
    hpdcache_cri_item cri;
    hpdcache_cmi_item cmi;
    bit [MEM_DATA_WIDTH/8-1:0] expected_mask;
    bit identity_mismatch;

    while (cri_transaction_q.size() != 0 &&
           cmi_transaction_q.size() != 0) begin
      cri = cri_transaction_q.pop_front();
      cmi = cmi_transaction_q.pop_front();
      compared_requests++;
      identity_mismatch = 1'b0;

      if (hpdcache_req_addr_t'(cmi.addr) !== cri.addr) begin
        identity_mismatch = 1'b1;
        `uvm_error("HPDCACHE_CHK_UNCACHEABLE", $sformatf(
          "uncacheable transaction address mismatch CRI=0x%0h CMI=0x%0h",
          cri.addr, cmi.addr))
      end
      if ((cri.op == HPDCACHE_REQ_LOAD && cmi.cmd != MEM_READ) ||
          (cri.op == HPDCACHE_REQ_STORE && cmi.cmd != MEM_WRITE)) begin
        identity_mismatch = 1'b1;
        `uvm_error("HPDCACHE_CHK_UNCACHEABLE", $sformatf(
          "uncacheable transaction command mismatch op=%s CMI_cmd=%0d",
          cri.op.name(), cmi.cmd))
      end
      if (identity_mismatch)
        order_mismatches++;

      expected_mask = '0;
      if (cri.op == HPDCACHE_REQ_LOAD) begin
        for (int unsigned i = 0; i < (1 << cri.size); i++)
          expected_mask[(cri.addr % (MEM_DATA_WIDTH / 8)) + i] = 1'b1;
      end else begin
        expected_mask = cri.be[0];
      end
      if (cmi.request_strb !== expected_mask)
        `uvm_error("HPDCACHE_CHK_UNCACHEABLE", $sformatf(
          "uncacheable transaction BE mismatch addr=0x%0h expected=0x%0h CMI=0x%0h",
          cri.addr, expected_mask, cmi.request_strb))

      if (cri.op == HPDCACHE_REQ_STORE) begin
        for (int i = 0; i < MEM_DATA_WIDTH/8; i++) begin
          if (expected_mask[i] &&
              cmi.request_data[i*8 +: 8] !== cri.data[0][i*8 +: 8])
            `uvm_error("HPDCACHE_CHK_UNCACHEABLE", $sformatf(
              "uncacheable write-data mismatch addr=0x%0h byte=%0d CRI=0x%02h CMI=0x%02h",
              cri.addr, i, cri.data[0][i*8 +: 8],
              cmi.request_data[i*8 +: 8]))
        end
      end

      if (cri.need_rsp) begin
        compared_responses++;
        if (!cmi.response_valid)
          `uvm_error("HPDCACHE_CHK_UNCACHEABLE", $sformatf(
            "uncacheable transaction ID 0x%0h has no CMI response", cmi.id))
        else begin
          if (cri.error !== cmi.err)
            `uvm_error("HPDCACHE_CHK_UNCACHEABLE", $sformatf(
              "uncacheable response error mismatch CRI=%0b CMI=%0b",
              cri.error, cmi.err))
          if (cri.op == HPDCACHE_REQ_LOAD && !cri.error && !cri.aborted &&
              cri.response_data[0] !== cmi.response_data)
            `uvm_error("HPDCACHE_CHK_UNCACHEABLE", $sformatf(
              "uncacheable read-data mismatch CRI=0x%0h CMI=0x%0h",
              cri.response_data[0], cmi.response_data))
        end
      end else begin
        no_response_transactions++;
      end
    end
  endfunction

  function automatic bit is_idle();
    return cri_transaction_q.size() == 0 && cmi_transaction_q.size() == 0;
  endfunction

  virtual task reset_phase(uvm_phase phase);
    super.reset_phase(phase);
    cri_transaction_q.delete();
    cmi_transaction_q.delete();
  endtask

  virtual function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (!is_idle())
      `uvm_error("HPDCACHE_CHK_UNCACHEABLE", $sformatf(
        "unmatched uncacheable transactions: CRI=%0d CMI=%0d",
        cri_transaction_q.size(), cmi_transaction_q.size()))
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("HPDCACHE_RPT_CHECK_UNCACHEABLE", $sformatf(
      "cri_requests=%0d cri_responses=%0d cmi_requests=%0d cmi_responses=%0d cri_responses_checked=%0d requests_checked=%0d responses_checked=%0d no_rsp=%0d",
      received_cri_requests, received_cri_responses,
      received_cmi_requests, received_cmi_responses,
      compared_responses, compared_requests, compared_responses,
      no_response_transactions), UVM_NONE)
    `uvm_info("HPDCACHE_RPT_CHECK_ABORT", $sformatf(
      "checked=%0d", checked_aborts), UVM_NONE)
    `uvm_info("HPDCACHE_RPT_CHECK_ORDER", $sformatf(
      "checked=%0d mismatches=%0d", compared_requests, order_mismatches),
      UVM_NONE)
  endfunction
endclass
