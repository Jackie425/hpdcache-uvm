class hpdcache_driver extends uvm_driver #(hpdcache_item);
  `uvm_component_utils(hpdcache_driver)

  typedef enum logic [1:0] {
    REQ_RESET,
    REQ_IDLE,
    REQ_WAIT_READY
  } request_state_e;

  virtual hpdcache_if vif;
  hpdcache_agent_config cfg;

  protected request_state_e request_state = REQ_RESET;
  protected hpdcache_item active_request;
  protected hpdcache_item outstanding_requests[hpdcache_req_tid_t];

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db#(virtual hpdcache_if)::get(this, "", "vif", vif))
      `uvm_fatal(get_type_name(), "hpdcache_if was not configured")
    if (cfg == null)
      `uvm_fatal(get_type_name(), "agent did not assign hpdcache_agent_config")
  endfunction

  virtual task run_phase(uvm_phase phase);
    drive_idle();
    fork
      drive_requests();
      collect_responses();
    join
  endtask

  protected task drive_requests();
    forever begin
      case (request_state)
        REQ_RESET:      wait_for_reset_release();
        REQ_IDLE:       get_and_drive_request();
        REQ_WAIT_READY: accept_request();
        default:        reset_state();
      endcase
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

  protected task get_and_drive_request();
    hpdcache_item sequence_request;
    hpdcache_item request;

    seq_item_port.get(sequence_request);
    if (sequence_request == null) begin
      `uvm_error(get_type_name(), "received a null request from the sequence")
      return;
    end
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
    request_state = REQ_WAIT_READY;
    drive_request(request);
  endtask

  protected task accept_request();
    @(vif.drv_cb);
    if (!vif.drv_cb.rst_ni) begin
      cancel_on_bus_reset();
      return;
    end
    if (request_state != REQ_WAIT_READY || !vif.drv_cb.req_ready)
      return;
    if (active_request == null)
      `uvm_fatal(get_type_name(), "REQ_WAIT_READY has no active request")

    outstanding_requests[active_request.tid] = active_request;
    active_request = null;
    request_state = REQ_IDLE;
    drive_idle();
  endtask

  protected function void validate_request(hpdcache_item request);
    if (request.sid != cfg.requester_id)
      `uvm_fatal(get_type_name(), $sformatf(
        "request SID %0d does not match configured SID %0d",
        request.sid, cfg.requester_id))
  endfunction

  protected function void drive_request(hpdcache_item tr);
    hpdcache_req_t driven_req;

    driven_req = '0;
    driven_req.addr_offset        = address_offset(tr.addr);
    driven_req.addr_tag           = address_tag(tr.addr);
    driven_req.wdata              = tr.data;
    driven_req.op                 = tr.op;
    driven_req.be                 = tr.be;
    driven_req.size               = tr.size;
    driven_req.sid                = tr.sid;
    driven_req.tid                = tr.tid;
    driven_req.need_rsp           = 1'b1;
    driven_req.phys_indexed       = 1'b1;
    driven_req.pma.uncacheable    = 1'b0;
    driven_req.pma.io             = 1'b0;
    driven_req.pma.wr_policy_hint = HPDCACHE_WR_POLICY_AUTO;

    vif.drv_cb.drv_req       <= driven_req;
    vif.drv_cb.drv_req_abort <= 1'b0;
    vif.drv_cb.drv_req_tag   <= address_tag(tr.addr);
    vif.drv_cb.drv_req_pma   <= driven_req.pma;
    vif.drv_cb.drv_req_valid <= 1'b1;
  endfunction

  protected function void drive_idle();
    vif.drv_cb.drv_req_valid <= 1'b0;
    vif.drv_cb.drv_req       <= '0;
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
    hpdcache_item request;
    hpdcache_item response;
    bit sid_error;

    tid = vif.drv_cb.rsp.tid;
    if (!outstanding_requests.exists(tid)) begin
      `uvm_error(get_type_name(), $sformatf(
        "response SID %0d has no outstanding TID %0d",
        vif.drv_cb.rsp.sid, int'(tid)))
      return;
    end
    request = outstanding_requests[tid];
    outstanding_requests.delete(tid);

    sid_error = vif.drv_cb.rsp.sid != cfg.requester_id;
    if (sid_error)
      `uvm_error(get_type_name(), $sformatf(
        "response SID %0d does not match configured SID %0d",
        vif.drv_cb.rsp.sid, cfg.requester_id))

    response = hpdcache_item::type_id::create("response");
    response.set_id_info(request);
    response.is_response = 1'b1;
    response.data        = vif.drv_cb.rsp.rdata;
    response.sid         = vif.drv_cb.rsp.sid;
    response.tid         = tid;
    response.error       = vif.drv_cb.rsp.error || sid_error;
    seq_item_port.put(response);
  endtask

  protected task put_reset_response(hpdcache_item request);
    hpdcache_item response;

    response = hpdcache_item::type_id::create("reset_response");
    response.set_id_info(request);
    response.is_response = 1'b1;
    response.sid         = request.sid;
    response.tid         = request.tid;
    response.error       = 1'b1;
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
        request_state = REQ_IDLE;
        return;
      end
    end
  endtask

  // A signal-level reset may occur without a UVM phase jump.  In that case the
  // issuing sequences are still alive, so wake each response handler with an
  // error response; each handler then returns its TID to the manager.
  protected task cancel_on_bus_reset();
    hpdcache_item cancelled_requests[$];

    // Snapshot and clear all shared state before the first blocking put().
    request_state = REQ_RESET;
    drive_idle();
    if (active_request != null) begin
      cancelled_requests.push_back(active_request);
      active_request = null;
    end
    foreach (outstanding_requests[tid])
      cancelled_requests.push_back(outstanding_requests[tid]);
    outstanding_requests.delete();

    foreach (cancelled_requests[i])
      put_reset_response(cancelled_requests[i]);
  endtask

  // A UVM reset phase kills old sequences before calling this task.  Their
  // requests must therefore be discarded, not routed to defunct response queues.
  function void reset_state();
    request_state = REQ_RESET;
    drive_idle();
    active_request = null;
    outstanding_requests.delete();
  endfunction

  function automatic bit is_idle();
    return active_request == null && outstanding_requests.num() == 0;
  endfunction

  function automatic int unsigned num_outstanding();
    return outstanding_requests.num();
  endfunction
endclass
