`uvm_analysis_imp_decl(_uc_cri_request)
`uvm_analysis_imp_decl(_uc_cri_response)
`uvm_analysis_imp_decl(_uc_cmi_request)
`uvm_analysis_imp_decl(_uc_cmi_response)
class hpdcache_uncacheable_evaluator extends uvm_component;
  `uvm_component_utils(hpdcache_uncacheable_evaluator)

  typedef memory_txn#(MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH) mem_item_t;

  uvm_analysis_imp_uc_cri_request #(
    hpdcache_cri_item, hpdcache_uncacheable_evaluator
  ) cri_request_imp;
  uvm_analysis_imp_uc_cri_response #(
    hpdcache_cri_item, hpdcache_uncacheable_evaluator
  ) cri_response_imp;
  uvm_analysis_imp_uc_cmi_request #(
    mem_item_t, hpdcache_uncacheable_evaluator
  ) cmi_request_imp;
  uvm_analysis_imp_uc_cmi_response #(
    mem_item_t, hpdcache_uncacheable_evaluator
  ) cmi_response_imp;

  hpdcache_pma_config pma_cfg;
  protected hpdcache_cri_item cri_request_q[$];
  protected mem_item_t cmi_request_q[$];
  protected hpdcache_cri_item pending_cri_response_requests[$];
  protected hpdcache_cri_item cri_response_q[$];
  protected mem_item_t cmi_response_q[$];
  protected bit response_needed_q[$];

  protected int unsigned received_cri_requests;
  protected int unsigned received_cmi_requests;
  protected int unsigned received_cri_responses;
  protected int unsigned received_cmi_responses;
  protected int unsigned compared_requests;
  protected int unsigned compared_cri_responses;
  protected int unsigned compared_responses;
  protected int unsigned cri_response_order_mismatches;
  protected int unsigned checked_aborts;
  protected int unsigned dropped_no_rsp;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cri_request_imp = new("cri_request_imp", this);
    cri_response_imp = new("cri_response_imp", this);
    cmi_request_imp = new("cmi_request_imp", this);
    cmi_response_imp = new("cmi_response_imp", this);
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

  function void write_uc_cri_request(hpdcache_cri_item t);
    hpdcache_cri_item snapshot;

    if (!is_forwarded_operation(t.op) ||
        !pma_cfg.is_uncacheable(t.addr))
      return;
    if (!$cast(snapshot, t.clone()))
      `uvm_fatal(get_type_name(), "failed to clone uncacheable CRI request")
    received_cri_requests++;
    if (t.pma.uncacheable !== 1'b1)
      `uvm_error("HPDCACHE_CHK_UNCACHEABLE", $sformatf(
        "PMA marks address 0x%0h uncacheable but CRI did not", t.addr))
    if (t.need_rsp)
      pending_cri_response_requests.push_back(snapshot);
    if (t.abort) begin
      if (!t.need_rsp)
        checked_aborts++;
      return;
    end
    cri_request_q.push_back(snapshot);
    compare_requests();
  endfunction

  protected function int find_pending_cri_response_request(
    hpdcache_cri_item response
  );
    for (int i = 0; i < pending_cri_response_requests.size(); i++) begin
      if (pending_cri_response_requests[i].sid === response.sid &&
          pending_cri_response_requests[i].tid === response.tid)
        return i;
    end
    return -1;
  endfunction

  function void write_uc_cmi_request(mem_item_t t);
    mem_item_t snapshot;

    if (t.cmd == MEM_ATOMIC)
      return;
    if (!$cast(snapshot, t.clone()))
      `uvm_fatal(get_type_name(), "failed to clone uncacheable CMI request")
    received_cmi_requests++;
    cmi_request_q.push_back(snapshot);
    compare_requests();
  endfunction

  function void write_uc_cri_response(hpdcache_cri_item t);
    hpdcache_cri_item request;
    hpdcache_cri_item snapshot;
    int request_index;

    request_index = find_pending_cri_response_request(t);
    if (request_index < 0)
      return;

    received_cri_responses++;
    compared_cri_responses++;
    if (request_index != 0) begin
      cri_response_order_mismatches++;
      `uvm_error("HPDCACHE_CHK_ORDER", $sformatf(
        "uncacheable CRI response order mismatch expected SID=%0d TID=%0d actual SID=%0d TID=%0d",
        pending_cri_response_requests[0].sid,
        pending_cri_response_requests[0].tid, t.sid, t.tid))
    end
    request = pending_cri_response_requests[request_index];
    pending_cri_response_requests.delete(request_index);

    if (t.aborted !== request.abort)
      `uvm_error("HPDCACHE_CHK_ABORT", $sformatf(
        "uncacheable CRI response abort mismatch SID %0d TID %0d expected=%0b actual=%0b",
        request.sid, request.tid, request.abort, t.aborted))

    if (request.abort) begin
      checked_aborts++;
      if (t.error !== 1'b0)
        `uvm_error("HPDCACHE_CHK_ABORT", $sformatf(
          "aborted CRI request SID %0d TID %0d returned error=%0b",
          request.sid, request.tid, t.error))
      return;
    end

    if (!$cast(snapshot, t.clone()))
      `uvm_fatal(get_type_name(), "failed to clone uncacheable CRI response")
    cri_response_q.push_back(snapshot);
    compare_responses();
  endfunction

  function void write_uc_cmi_response(mem_item_t t);
    bit response_needed;
    mem_item_t snapshot;

    if (t.cmd == MEM_ATOMIC)
      return;
    received_cmi_responses++;
    if (response_needed_q.size() == 0) begin
      `uvm_error("HPDCACHE_CHK_UNCACHEABLE", $sformatf(
        "CMI response cmd=%0d has no forwarded CRI request", t.cmd))
      return;
    end
    response_needed = response_needed_q.pop_front();
    if (!response_needed) begin
      dropped_no_rsp++;
      return;
    end
    if (!$cast(snapshot, t.clone()))
      `uvm_fatal(get_type_name(), "failed to clone uncacheable CMI response")
    cmi_response_q.push_back(snapshot);
    compare_responses();
  endfunction

  protected function void compare_requests();
    hpdcache_cri_item cri;
    mem_item_t cmi;
    bit [MEM_DATA_WIDTH/8-1:0] expected_mask;

    while (cri_request_q.size() != 0 && cmi_request_q.size() != 0) begin
      cri = cri_request_q.pop_front();
      cmi = cmi_request_q.pop_front();
      compared_requests++;
      response_needed_q.push_back(cri.need_rsp);

      if (hpdcache_req_addr_t'(cmi.addr) !== cri.addr)
        `uvm_error("HPDCACHE_CHK_UNCACHEABLE", $sformatf(
          "uncacheable request address mismatch CRI=0x%0h CMI=0x%0h",
          cri.addr, cmi.addr))
      if ((cri.op == HPDCACHE_REQ_LOAD && cmi.cmd != MEM_READ) ||
          (cri.op == HPDCACHE_REQ_STORE && cmi.cmd != MEM_WRITE))
        `uvm_error("HPDCACHE_CHK_UNCACHEABLE", $sformatf(
          "uncacheable command mismatch op=%s CMI_cmd=%0d",
          cri.op.name(), cmi.cmd))

      expected_mask = '0;
      if (cri.op == HPDCACHE_REQ_LOAD) begin
        for (int unsigned i = 0; i < (1 << cri.size); i++)
          expected_mask[(cri.addr % (MEM_DATA_WIDTH / 8)) + i] = 1'b1;
      end else begin
        expected_mask = cri.be[0];
      end
      if (cmi.strb !== expected_mask)
        `uvm_error("HPDCACHE_CHK_UNCACHEABLE", $sformatf(
          "uncacheable request BE mismatch addr=0x%0h CRI/expected=0x%0h CMI=0x%0h",
          cri.addr, expected_mask, cmi.strb))

      if (cri.op == HPDCACHE_REQ_STORE) begin
        for (int i = 0; i < MEM_DATA_WIDTH/8; i++) begin
          if (expected_mask[i] &&
              cmi.data[i*8 +: 8] !== cri.data[0][i*8 +: 8])
            `uvm_error("HPDCACHE_CHK_UNCACHEABLE", $sformatf(
              "uncacheable write-data mismatch addr=0x%0h byte=%0d CRI=0x%02h CMI=0x%02h",
              cri.addr, i, cri.data[0][i*8 +: 8], cmi.data[i*8 +: 8]))
        end
      end
    end
  endfunction

  protected function void compare_responses();
    hpdcache_cri_item cri;
    mem_item_t cmi;

    while (cri_response_q.size() != 0 && cmi_response_q.size() != 0) begin
      cri = cri_response_q.pop_front();
      cmi = cmi_response_q.pop_front();
      compared_responses++;
      if (cri.error !== cmi.err)
        `uvm_error("HPDCACHE_CHK_UNCACHEABLE", $sformatf(
          "uncacheable response error mismatch CRI=%0b CMI=%0b",
          cri.error, cmi.err))
      if (cmi.cmd == MEM_READ && !cri.error && !cri.aborted &&
          cri.data[0] !== cmi.data)
        `uvm_error("HPDCACHE_CHK_UNCACHEABLE", $sformatf(
          "uncacheable read-data mismatch CRI=0x%0h CMI=0x%0h",
          cri.data[0], cmi.data))
    end
  endfunction

  function automatic bit is_idle();
    return cri_request_q.size() == 0 && cmi_request_q.size() == 0 &&
           pending_cri_response_requests.size() == 0 &&
           cri_response_q.size() == 0 && cmi_response_q.size() == 0 &&
           response_needed_q.size() == 0;
  endfunction

  virtual task reset_phase(uvm_phase phase);
    super.reset_phase(phase);
    cri_request_q.delete();
    cmi_request_q.delete();
    pending_cri_response_requests.delete();
    cri_response_q.delete();
    cmi_response_q.delete();
    response_needed_q.delete();
  endtask

  virtual function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (!is_idle())
      `uvm_error("HPDCACHE_CHK_UNCACHEABLE", $sformatf(
        "unmatched uncacheable entries: CRI_req=%0d CMI_req=%0d pending_CRI_rsp=%0d CRI_rsp=%0d CMI_rsp=%0d pending_CMI_rsp=%0d",
        cri_request_q.size(), cmi_request_q.size(),
        pending_cri_response_requests.size(), cri_response_q.size(),
        cmi_response_q.size(), response_needed_q.size()))
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("HPDCACHE_RPT_CHECK_UNCACHEABLE", $sformatf(
      "cri_requests=%0d cri_responses=%0d cmi_requests=%0d cmi_responses=%0d cri_responses_checked=%0d requests_checked=%0d responses_checked=%0d no_rsp=%0d",
      received_cri_requests, received_cri_responses, received_cmi_requests,
      received_cmi_responses, compared_cri_responses, compared_requests,
      compared_responses, dropped_no_rsp), UVM_NONE)
    `uvm_info("HPDCACHE_RPT_CHECK_ABORT", $sformatf(
      "checked=%0d", checked_aborts), UVM_NONE)
    `uvm_info("HPDCACHE_RPT_CHECK_ORDER", $sformatf(
      "checked=%0d mismatches=%0d", compared_cri_responses,
      cri_response_order_mismatches), UVM_NONE)
  endfunction
endclass
