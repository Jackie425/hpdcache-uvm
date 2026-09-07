`uvm_analysis_imp_decl(_uc_amo_cri_item)
`uvm_analysis_imp_decl(_uc_amo_cmi_read_item)
`uvm_analysis_imp_decl(_uc_amo_cmi_write_item)
`uvm_analysis_imp_decl(_uc_amo_cmi_atomic_item)
`uvm_analysis_imp_decl(_uc_amo_sc_expected)

class hpdcache_uc_amo_forwarding_evaluator extends uvm_component;
  `uvm_component_utils(hpdcache_uc_amo_forwarding_evaluator)

  uvm_analysis_imp_uc_amo_cri_item #(
    hpdcache_cri_item, hpdcache_uc_amo_forwarding_evaluator
  ) cri_item_imp;
  uvm_analysis_imp_uc_amo_cmi_read_item #(
    hpdcache_cmi_read_item, hpdcache_uc_amo_forwarding_evaluator
  ) cmi_read_item_imp;
  uvm_analysis_imp_uc_amo_cmi_write_item #(
    hpdcache_cmi_write_item, hpdcache_uc_amo_forwarding_evaluator
  ) cmi_write_item_imp;
  uvm_analysis_imp_uc_amo_cmi_atomic_item #(
    hpdcache_cmi_atomic_item, hpdcache_uc_amo_forwarding_evaluator
  ) cmi_atomic_item_imp;
  uvm_analysis_imp_uc_amo_sc_expected #(
    hpdcache_cri_item, hpdcache_uc_amo_forwarding_evaluator
  ) sc_expected_imp;

  localparam int unsigned SID_W = $bits(hpdcache_req_sid_t);
  localparam int unsigned TID_W = $bits(hpdcache_req_tid_t);
  typedef bit [SID_W+TID_W-1:0] key_t;

  hpdcache_pma_config pma_cfg;
  protected hpdcache_cri_item cri_transaction_q[$];
  protected hpdcache_cmi_item cmi_transaction_q[$];
  protected bit sc_expect_cmi_q[key_t][$];

  protected int unsigned received_cri_requests;
  protected int unsigned received_cmi_requests;
  protected int unsigned received_cri_responses;
  protected int unsigned received_cmi_responses;
  protected int unsigned compared_requests;
  protected int unsigned compared_responses;
  protected int unsigned order_mismatches;
  protected int unsigned checked_aborts;
  protected int unsigned no_response_transactions;
  protected int unsigned checked_atomics;
  protected int unsigned received_cacheable_atomics;
  protected int unsigned checked_cacheable_atomics;
  protected int unsigned local_sc_failures;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cri_item_imp = new("cri_item_imp", this);
    cmi_read_item_imp = new("cmi_read_item_imp", this);
    cmi_write_item_imp = new("cmi_write_item_imp", this);
    cmi_atomic_item_imp = new("cmi_atomic_item_imp", this);
    sc_expected_imp = new("sc_expected_imp", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(hpdcache_pma_config)::get(
          this, "", "pma_cfg", pma_cfg) || pma_cfg == null)
      `uvm_fatal(get_type_name(), "hpdcache_pma_config was not configured")
  endfunction

  function automatic bit is_forwarded_operation(hpdcache_req_op_t op);
    return op inside {HPDCACHE_REQ_LOAD, HPDCACHE_REQ_STORE} || is_amo(op);
  endfunction

  function automatic mem_atomic_t expected_atomic(hpdcache_req_op_t op);
    case (op)
      HPDCACHE_REQ_AMO_LR:   return MEM_ATOMIC_LDEX;
      HPDCACHE_REQ_AMO_SC:   return MEM_ATOMIC_STEX;
      HPDCACHE_REQ_AMO_SWAP: return MEM_ATOMIC_SWAP;
      HPDCACHE_REQ_AMO_ADD:  return MEM_ATOMIC_ADD;
      HPDCACHE_REQ_AMO_AND:  return MEM_ATOMIC_CLR;
      HPDCACHE_REQ_AMO_OR:   return MEM_ATOMIC_SET;
      HPDCACHE_REQ_AMO_XOR:  return MEM_ATOMIC_EOR;
      HPDCACHE_REQ_AMO_MAX:  return MEM_ATOMIC_SMAX;
      HPDCACHE_REQ_AMO_MAXU: return MEM_ATOMIC_UMAX;
      HPDCACHE_REQ_AMO_MIN:  return MEM_ATOMIC_SMIN;
      HPDCACHE_REQ_AMO_MINU: return MEM_ATOMIC_UMIN;
      default:               return MEM_ATOMIC_ADD;
    endcase
  endfunction

  function automatic bit sc_failed(hpdcache_cri_item cri);
    int unsigned byte_offset;

    byte_offset = longint'(cri.addr) % (REQ_WORDS * (WORD_WIDTH / 8));
    return cri.op == HPDCACHE_REQ_AMO_SC && !cri.error && !cri.aborted &&
           cri.response_data[0][byte_offset*8 +: 8] != 0;
  endfunction

  function automatic key_t key(hpdcache_cri_item t);
    return {t.sid, t.tid};
  endfunction

  function automatic int unsigned num_pending_sc_expectations();
    key_t transaction_key;
    int unsigned pending;

    pending = 0;
    foreach (sc_expect_cmi_q[transaction_key])
      pending += sc_expect_cmi_q[transaction_key].size();
    return pending;
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

  function void write_uc_amo_cri_item(hpdcache_cri_item t);
    // All AMOs are tracked regardless of PMA: the HPDcache forwards AMOs to
    // CMI even when the original address is cacheable.  Ordinary LOAD/STORE
    // traffic is tracked here only for PMA-uncacheable requests.
    if (!is_forwarded_operation(t.op) ||
        (!is_amo(t.op) && !pma_cfg.is_uncacheable(t.addr)))
      return;

    received_cri_requests++;
    if (is_amo(t.op) && !pma_cfg.is_uncacheable(t.addr))
      received_cacheable_atomics++;
    if (t.need_rsp)
      received_cri_responses++;
    if (!is_amo(t.op) && t.pma.uncacheable !== 1'b1)
      `uvm_error("HPDCACHE_CHK_UC_AMO_FORWARDING", $sformatf(
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
    if (!t.request_valid || t.request_cacheable)
      return;
    received_cmi_requests++;
    if (t.response_valid)
      received_cmi_responses++;
    snapshot = clone_cmi(t);
    cmi_transaction_q.push_back(snapshot);
    compare_transactions();
  endfunction

  function void write_uc_amo_cmi_read_item(hpdcache_cmi_read_item t);
    enqueue_cmi(t);
  endfunction

  function void write_uc_amo_cmi_write_item(hpdcache_cmi_write_item t);
    enqueue_cmi(t);
  endfunction

  function void write_uc_amo_cmi_atomic_item(hpdcache_cmi_atomic_item t);
    hpdcache_cmi_item snapshot;

    if (!t.request_valid)
      return;
    // Do not filter atomic CMI by request_cacheable.  Cacheable and
    // uncacheable AMOs share this forwarding FIFO and are compared in order.
    received_cmi_requests++;
    if (t.response_valid)
      received_cmi_responses++;
    snapshot = clone_cmi(t);
    cmi_transaction_q.push_back(snapshot);
    compare_transactions();
  endfunction

  function void write_uc_amo_sc_expected(hpdcache_cri_item t);
    if (t.op != HPDCACHE_REQ_AMO_SC || t.aborted)
      return;
    if (!t.sc_expect_cmi_valid) begin
      `uvm_error("HPDCACHE_CHK_UC_AMO_FORWARDING", $sformatf(
        "SC expectation is missing forwarding state SID=%0d TID=%0d",
        t.sid, t.tid))
      return;
    end
    sc_expect_cmi_q[key(t)].push_back(t.sc_expect_cmi);
    compare_transactions();
  endfunction

  protected function void compare_transactions();
    hpdcache_cri_item cri;
    hpdcache_cmi_item cmi;
    bit [MEM_DATA_WIDTH/8-1:0] expected_mask;
    logic [7:0] expected_byte;
    bit identity_mismatch;
    key_t transaction_key;

    while (cri_transaction_q.size() != 0) begin
      if (cri_transaction_q[0].op == HPDCACHE_REQ_AMO_SC &&
          !cri_transaction_q[0].sc_expect_cmi_valid) begin
        transaction_key = key(cri_transaction_q[0]);
        if (!sc_expect_cmi_q.exists(transaction_key) ||
            sc_expect_cmi_q[transaction_key].size() == 0)
          return;
        cri_transaction_q[0].sc_expect_cmi =
          sc_expect_cmi_q[transaction_key].pop_front();
        cri_transaction_q[0].sc_expect_cmi_valid = 1'b1;
        if (sc_expect_cmi_q[transaction_key].size() == 0)
          sc_expect_cmi_q.delete(transaction_key);
      end

      if (cri_transaction_q[0].op == HPDCACHE_REQ_AMO_SC &&
          !cri_transaction_q[0].sc_expect_cmi) begin
        cri = cri_transaction_q.pop_front();
        local_sc_failures++;
        checked_atomics++;
        if (is_amo(cri.op) && !pma_cfg.is_uncacheable(cri.addr))
          checked_cacheable_atomics++;
      if (!sc_failed(cri))
        `uvm_error("HPDCACHE_CHK_UC_AMO_FORWARDING", $sformatf(
            "SC predicted as local failure returned status=0x%0h error=%0b aborted=%0b addr=0x%0h",
            cri.response_data, cri.error, cri.aborted, cri.addr))
        continue;
      end

      if (cmi_transaction_q.size() == 0)
        return;
      cri = cri_transaction_q.pop_front();
      cmi = cmi_transaction_q.pop_front();
      compared_requests++;
      identity_mismatch = 1'b0;

      if (hpdcache_req_addr_t'(cmi.addr) !== cri.addr) begin
        identity_mismatch = 1'b1;
        `uvm_error("HPDCACHE_CHK_UC_AMO_FORWARDING", $sformatf(
          "uncacheable transaction address mismatch CRI=0x%0h CMI=0x%0h",
          cri.addr, cmi.addr))
      end
      if ((cri.op == HPDCACHE_REQ_LOAD && cmi.cmd != MEM_READ) ||
          (cri.op == HPDCACHE_REQ_STORE && cmi.cmd != MEM_WRITE) ||
          (is_amo(cri.op) && cmi.cmd != MEM_ATOMIC)) begin
        identity_mismatch = 1'b1;
        `uvm_error("HPDCACHE_CHK_UC_AMO_FORWARDING", $sformatf(
          "uncacheable transaction command mismatch op=%s CMI_cmd=%0d",
          cri.op.name(), cmi.cmd))
      end
      if (is_amo(cri.op) && cmi.atop != expected_atomic(cri.op)) begin
        identity_mismatch = 1'b1;
        `uvm_error("HPDCACHE_CHK_UC_AMO_FORWARDING", $sformatf(
          "atomic operation mismatch CRI=%s expected_CMI=%s actual_CMI=%s",
          cri.op.name(), expected_atomic(cri.op).name(), cmi.atop.name()))
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
        `uvm_error("HPDCACHE_CHK_UC_AMO_FORWARDING", $sformatf(
          "uncacheable transaction BE mismatch addr=0x%0h expected=0x%0h CMI=0x%0h",
          cri.addr, expected_mask, cmi.request_strb))

      if (cri.op == HPDCACHE_REQ_STORE ||
          (is_amo(cri.op) && cri.op != HPDCACHE_REQ_AMO_LR)) begin
        for (int i = 0; i < MEM_DATA_WIDTH/8; i++) begin
          expected_byte = cri.data[0][i*8 +: 8];
          if (cri.op == HPDCACHE_REQ_AMO_AND)
            expected_byte = ~expected_byte;
          if (expected_mask[i] &&
              cmi.request_data[i*8 +: 8] !== expected_byte)
            `uvm_error("HPDCACHE_CHK_UC_AMO_FORWARDING", $sformatf(
              "uncacheable write-data mismatch addr=0x%0h byte=%0d CRI=0x%02h CMI=0x%02h",
              cri.addr, i, expected_byte,
              cmi.request_data[i*8 +: 8]))
        end
      end

      if (cri.need_rsp) begin
        compared_responses++;
        if (!cmi.response_valid)
          `uvm_error("HPDCACHE_CHK_UC_AMO_FORWARDING", $sformatf(
            "uncacheable transaction ID 0x%0h has no CMI response", cmi.id))
        else begin
          if (cri.error !== cmi.err)
            `uvm_error("HPDCACHE_CHK_UC_AMO_FORWARDING", $sformatf(
              "uncacheable response error mismatch CRI=%0b CMI=%0b",
              cri.error, cmi.err))
          if (!cri.error && !cri.aborted &&
              (cri.op == HPDCACHE_REQ_LOAD ||
               (is_amo(cri.op) && cri.op != HPDCACHE_REQ_AMO_SC))) begin
            for (int i = 0; i < MEM_DATA_WIDTH/8; i++) begin
              if (expected_mask[i] &&
                  cri.response_data[0][i*8 +: 8] !==
                    cmi.response_data[i*8 +: 8])
                `uvm_error("HPDCACHE_CHK_UC_AMO_FORWARDING", $sformatf(
                  "uncacheable read-data mismatch addr=0x%0h byte=%0d CRI=0x%02h CMI=0x%02h",
                  cri.addr, i, cri.response_data[0][i*8 +: 8],
                  cmi.response_data[i*8 +: 8]))
            end
          end
          if (!cri.error && !cri.aborted &&
              cri.op == HPDCACHE_REQ_AMO_SC) begin
            for (int i = 0; i < MEM_DATA_WIDTH/8; i++) begin
              expected_byte = (i == (cri.addr % (MEM_DATA_WIDTH / 8)) &&
                               !cmi.exclusive_success) ? 8'h01 : 8'h00;
              if (expected_mask[i] &&
                  cri.response_data[0][i*8 +: 8] !== expected_byte)
                `uvm_error("HPDCACHE_CHK_UC_AMO_FORWARDING", $sformatf(
                  "SC status mismatch addr=0x%0h byte=%0d expected=0x%02h CRI=0x%02h",
                  cri.addr, i, expected_byte,
                  cri.response_data[0][i*8 +: 8]))
            end
          end
          if (is_amo(cri.op))
            checked_atomics++;
          if (is_amo(cri.op) && !pma_cfg.is_uncacheable(cri.addr))
            checked_cacheable_atomics++;
        end
      end else begin
        no_response_transactions++;
      end
    end
  endfunction

  function automatic bit is_idle();
    return cri_transaction_q.size() == 0 &&
           cmi_transaction_q.size() == 0 &&
           sc_expect_cmi_q.num() == 0;
  endfunction

  virtual task reset_phase(uvm_phase phase);
    super.reset_phase(phase);
    cri_transaction_q.delete();
    cmi_transaction_q.delete();
    sc_expect_cmi_q.delete();
  endtask

  virtual function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (!is_idle())
      `uvm_error("HPDCACHE_CHK_UC_AMO_FORWARDING", $sformatf(
        "unmatched uncacheable transactions: CRI=%0d CMI=%0d SC_expectations=%0d",
        cri_transaction_q.size(), cmi_transaction_q.size(),
        num_pending_sc_expectations()))
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("HPDCACHE_RPT_CHECK_UC_AMO_FORWARDING", $sformatf(
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
    `uvm_info("HPDCACHE_RPT_CHECK_ATOMIC", $sformatf(
      "checked=%0d local_sc_failures=%0d cacheable_amo_received=%0d cacheable_amo_checked=%0d",
      checked_atomics, local_sc_failures, received_cacheable_atomics,
      checked_cacheable_atomics), UVM_NONE)
  endfunction
endclass
