class hpdcache_cri_driver extends uvm_driver #(hpdcache_cri_item);
  `uvm_component_utils(hpdcache_cri_driver)

  typedef enum logic [1:0] {
    REQ_RESET,
    REQ_IDLE,
    REQ_DELAY,
    REQ_WAIT_READY
  } request_state_e;

  virtual hpdcache_cri_if vif;
  hpdcache_cri_agent_config cfg;
  hpdcache_pma_config pma_cfg;

  protected request_state_e request_state = REQ_RESET;
  protected hpdcache_cri_item active_request;
  protected hpdcache_cri_item active_tag_request;
  protected hpdcache_cri_item outstanding_requests[hpdcache_req_tid_t];
  protected mailbox #(hpdcache_cri_item) tag_pipeline;
  protected bit reset_was_processed;
  protected int unsigned delay_cycles_remaining;

  protected int unsigned accepted_requests;
  protected int unsigned driven_tags;
  protected int unsigned received_responses;
  protected int unsigned aborted_responses;
  protected int unsigned no_response_completions;
  protected int unsigned reset_cancelled_requests;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    tag_pipeline = new();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual hpdcache_cri_if)::get(this, "", "vif", vif))
      `uvm_fatal(get_type_name(), "hpdcache_cri_if was not configured")
    if (!uvm_config_db#(hpdcache_cri_agent_config)::get(this, "", "cfg", cfg) ||
        cfg == null)
      `uvm_fatal(get_type_name(), "hpdcache_cri_agent_config was not configured")
    pma_cfg = cfg.pma_cfg;
  endfunction

  virtual task run_phase(uvm_phase phase);
    drive_request_idle();
    drive_tag_idle();
    fork
      drive_requests();
      drive_tag_pipeline();
      collect_responses();
    join
  endtask

  protected task drive_requests();
    forever begin
      case (request_state)
        REQ_RESET:      wait_for_reset_release();
        REQ_IDLE:       get_and_drive_request();
        REQ_DELAY:      wait_request_delay();
        REQ_WAIT_READY: accept_request();
        default:        reset_state();
      endcase
    end
  endtask

  protected task get_and_drive_request();
    hpdcache_cri_item sequence_request;
    hpdcache_cri_item request;

    seq_item_port.get(sequence_request);
    if (sequence_request == null)
      `uvm_fatal(get_type_name(), "received a null request from the sequence")
    if (!$cast(request, sequence_request.clone()))
      `uvm_fatal(get_type_name(), "failed to clone sequence request")
    request.set_id_info(sequence_request);
    validate_request(request);
    wait_for_reset_release();

    if (outstanding_requests.exists(request.tid))
      `uvm_fatal(get_type_name(), $sformatf(
        "requester %0d reused outstanding TID %0d",
        cfg.requester_id, int'(request.tid)))
    active_request = request;
    delay_cycles_remaining = request.delay;
    if (delay_cycles_remaining == 0) begin
      request_state = REQ_WAIT_READY;
      drive_request(request);
    end else begin
      request_state = REQ_DELAY;
      drive_request_idle();
    end
  endtask

  protected task wait_request_delay();
    @(vif.drv_cb);
    if (!vif.drv_cb.rst_ni) begin
      cancel_on_bus_reset();
      return;
    end
    if (request_state != REQ_DELAY)
      return;
    if (active_request == null)
      `uvm_fatal(get_type_name(), "REQ_DELAY has no active request")

    delay_cycles_remaining--;
    if (delay_cycles_remaining == 0) begin
      request_state = REQ_WAIT_READY;
      drive_request(active_request);
    end
  endtask

  protected task accept_request();
    hpdcache_cri_item request;

    @(vif.drv_cb);
    if (!vif.drv_cb.rst_ni) begin
      cancel_on_bus_reset();
      return;
    end
    if (request_state != REQ_WAIT_READY || !vif.drv_cb.req_ready)
      return;
    if (active_request == null)
      `uvm_fatal(get_type_name(), "REQ_WAIT_READY has no active request")

    request = active_request;
    accepted_requests++;
    if (request.need_rsp)
      outstanding_requests[request.tid] = request;

    active_request = null;
    request_state = REQ_IDLE;
    drive_request_idle();

    if (!request.phys_indexed)
      tag_pipeline.put(request);
    else if (!request.need_rsp) begin
      no_response_completions++;
      put_completion(request, 1'b0);
    end
  endtask

  protected task drive_tag_pipeline();
    hpdcache_cri_item request;

    forever begin
      tag_pipeline.get(request);
      active_tag_request = request;
      drive_tag(request);
      @(vif.drv_cb);
      drive_tag_idle();

      if (!vif.drv_cb.rst_ni) begin
        cancel_on_bus_reset();
        active_tag_request = null;
        continue;
      end

      driven_tags++;
      active_tag_request = null;
      if (!request.need_rsp) begin
        no_response_completions++;
        put_completion(request, 1'b0);
      end
    end
  endtask

  protected task collect_responses();
    forever begin
      @(vif.drv_cb);
      if (!vif.drv_cb.rst_ni) begin
        cancel_on_bus_reset();
        continue;
      end

      if (vif.drv_cb.rsp_valid)
        complete_response();
    end
  endtask

  protected function void validate_request(hpdcache_cri_item request);
    if (request.sid != cfg.requester_id)
      `uvm_fatal(get_type_name(), $sformatf(
        "request SID %0d does not match configured SID %0d",
        request.sid, cfg.requester_id))
    if (request.abort && request.phys_indexed)
      `uvm_fatal(get_type_name(), "only a VIPT request may be aborted")
    if (!is_cmo(request.op)) begin
      if (!pma_cfg.is_mapped(request.addr))
        `uvm_fatal(get_type_name(), $sformatf(
          "request address 0x%0h is outside the PMA map", request.addr))
      if (request.pma.uncacheable != pma_cfg.is_uncacheable(request.addr))
        `uvm_fatal(get_type_name(), $sformatf(
          "request address 0x%0h has inconsistent cacheability", request.addr))
    end
  endfunction

  protected function void drive_request(hpdcache_cri_item tr);
    hpdcache_req_t driven_req;

    driven_req = '0;
    driven_req.addr_offset  = address_offset(tr.addr);
    driven_req.addr_tag     = tr.phys_indexed ? address_tag(tr.addr) : '0;
    driven_req.wdata        = tr.data;
    driven_req.op           = tr.op;
    driven_req.be           = tr.be;
    driven_req.size         = tr.size;
    driven_req.sid          = tr.sid;
    driven_req.tid          = tr.tid;
    driven_req.need_rsp     = tr.need_rsp;
    driven_req.phys_indexed = tr.phys_indexed;
    driven_req.pma          = tr.phys_indexed ? tr.pma : '{
      uncacheable:    1'b0,
      io:             1'b0,
      wr_policy_hint: HPDCACHE_WR_POLICY_AUTO
    };

    vif.drv_cb.drv_req       <= driven_req;
    vif.drv_cb.drv_req_valid <= 1'b1;
  endfunction

  protected function void drive_request_idle();
    vif.drv_cb.drv_req_valid <= 1'b0;
    vif.drv_cb.drv_req       <= '0;
  endfunction

  protected function void drive_tag(hpdcache_cri_item tr);
    vif.drv_cb.drv_req_abort <= tr.abort;
    vif.drv_cb.drv_req_tag   <= address_tag(tr.addr);
    vif.drv_cb.drv_req_pma   <= tr.pma;
  endfunction

  protected function void drive_tag_idle();
    vif.drv_cb.drv_req_abort <= 1'b0;
    vif.drv_cb.drv_req_tag   <= '0;
    vif.drv_cb.drv_req_pma   <= '{
      uncacheable:    1'b0,
      io:             1'b0,
      wr_policy_hint: HPDCACHE_WR_POLICY_AUTO
    };
  endfunction

  protected task complete_response();
    hpdcache_req_tid_t tid;
    hpdcache_cri_item request;
    hpdcache_cri_item response;
    bit sid_error;

    tid = vif.drv_cb.rsp.tid;
    if (!outstanding_requests.exists(tid)) begin
      `uvm_error("HPDCACHE_CHK_CRI", $sformatf(
        "response SID %0d has no outstanding TID %0d",
        vif.drv_cb.rsp.sid, int'(tid)))
      return;
    end
    request = outstanding_requests[tid];
    outstanding_requests.delete(tid);

    sid_error = vif.drv_cb.rsp.sid != cfg.requester_id;
    if (sid_error)
      `uvm_error("HPDCACHE_CHK_CRI", $sformatf(
        "response SID %0d does not match configured SID %0d",
        vif.drv_cb.rsp.sid, cfg.requester_id))

    if (!$cast(response, request.clone()))
      `uvm_fatal(get_type_name(), "failed to clone request for response")
    response.set_name("response");
    response.set_id_info(request);
    response.is_response = 1'b1;
    response.data        = vif.drv_cb.rsp.rdata;
    response.sid         = vif.drv_cb.rsp.sid;
    response.tid         = tid;
    response.error       = vif.drv_cb.rsp.error || sid_error;
    response.aborted     = vif.drv_cb.rsp.aborted;
    received_responses++;
    if (response.aborted)
      aborted_responses++;
    seq_item_port.put(response);
  endtask

  protected task put_completion(hpdcache_cri_item request, bit error);
    hpdcache_cri_item response;

    if (!$cast(response, request.clone()))
      `uvm_fatal(get_type_name(), "failed to clone request for completion")
    response.set_name("driver_completion");
    response.set_id_info(request);
    response.is_response = 1'b1;
    response.error       = error;
    seq_item_port.put(response);
  endtask

  protected task wait_for_reset_release();
    forever begin
      if (request_state != REQ_RESET && vif.rst_ni)
        return;

      @(vif.drv_cb);
      if (!vif.drv_cb.rst_ni)
        cancel_on_bus_reset();
      else begin
        reset_was_processed = 1'b0;
        request_state = REQ_IDLE;
        return;
      end
    end
  endtask

  protected task cancel_on_bus_reset();
    hpdcache_cri_item cancelled_requests[$];
    hpdcache_cri_item queued_tag;

    if (reset_was_processed)
      return;
    reset_was_processed = 1'b1;
    request_state = REQ_RESET;
    delay_cycles_remaining = 0;
    drive_request_idle();
    drive_tag_idle();

    if (active_request != null) begin
      cancelled_requests.push_back(active_request);
      active_request = null;
    end
    foreach (outstanding_requests[tid])
      cancelled_requests.push_back(outstanding_requests[tid]);
    outstanding_requests.delete();

    if (active_tag_request != null && !active_tag_request.need_rsp)
      cancelled_requests.push_back(active_tag_request);
    active_tag_request = null;
    while (tag_pipeline.try_get(queued_tag)) begin
      if (!queued_tag.need_rsp)
        cancelled_requests.push_back(queued_tag);
    end

    foreach (cancelled_requests[i])
      put_completion(cancelled_requests[i], 1'b1);
    reset_cancelled_requests += cancelled_requests.size();
  endtask

  function void reset_state();
    hpdcache_cri_item queued_tag;

    request_state = REQ_RESET;
    delay_cycles_remaining = 0;
    drive_request_idle();
    drive_tag_idle();
    active_request = null;
    active_tag_request = null;
    outstanding_requests.delete();
    while (tag_pipeline.try_get(queued_tag)) begin
    end
  endfunction

  function automatic bit is_idle();
    return active_request == null &&
           active_tag_request == null &&
           tag_pipeline.num() == 0 &&
           outstanding_requests.num() == 0;
  endfunction

  function automatic int unsigned num_outstanding();
    return outstanding_requests.num();
  endfunction

  function automatic int unsigned num_reset_cancelled();
    return reset_cancelled_requests;
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info(get_type_name(), $sformatf(
      "accepted=%0d VIPT_tags=%0d responses=%0d aborted_responses=%0d no_rsp_completions=%0d reset_cancelled=%0d",
      accepted_requests, driven_tags, received_responses, aborted_responses,
      no_response_completions, reset_cancelled_requests), UVM_LOW)
  endfunction
endclass
