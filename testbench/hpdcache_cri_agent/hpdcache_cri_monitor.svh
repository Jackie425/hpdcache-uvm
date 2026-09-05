class hpdcache_cri_monitor extends uvm_monitor;
  `uvm_component_utils(hpdcache_cri_monitor)

  virtual hpdcache_cri_if vif;
  hpdcache_cri_agent_config cfg;

  // Typed channel ports used by the hierarchical CRI transaction model.
  uvm_analysis_port #(hpdcache_cri_req_item)  req_ap;
  uvm_analysis_port #(hpdcache_cri_resp_item) resp_ap;
  uvm_analysis_port #(hpdcache_cri_item)      cri_ap;

  localparam int unsigned SID_W = $bits(hpdcache_req_sid_t);
  localparam int unsigned TID_W = $bits(hpdcache_req_tid_t);
  typedef bit [SID_W+TID_W-1:0] transaction_key_t;

  protected hpdcache_cri_req_item pending_requests[$];
  protected hpdcache_cri_item pending_transactions[transaction_key_t];
  protected int unsigned observed_requests;
  protected int unsigned observed_vipt_requests;
  protected int unsigned observed_aborts;
  protected int unsigned observed_responses;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    req_ap  = new("req_ap", this);
    resp_ap = new("resp_ap", this);
    cri_ap  = new("cri_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual hpdcache_cri_if)::get(this, "", "vif", vif))
      `uvm_fatal(get_type_name(), "hpdcache_cri_if was not configured")
    if (!uvm_config_db#(hpdcache_cri_agent_config)::get(
          this, "", "cfg", cfg) || cfg == null)
      `uvm_fatal(get_type_name(), "hpdcache_cri_agent_config was not configured")
  endfunction

  virtual task run_phase(uvm_phase phase);
    super.run_phase(phase);
    forever begin
      @(vif.mon_cb);
      if (!vif.mon_cb.rst_ni) begin
        reset_state();
        continue;
      end

      complete_request();
      if (vif.mon_cb.req_valid && vif.mon_cb.req_ready)
        sample_request();
      if (vif.mon_cb.rsp_valid)
        sample_response();
    end
  endtask

  protected function void sample_request();
    hpdcache_cri_req_item item;

    if (vif.mon_cb.req.sid !== hpdcache_req_sid_t'(cfg.requester_id))
      `uvm_error("HPDCACHE_CHK_CRI", $sformatf(
        "request on requester port %0d has SID %0d",
        cfg.requester_id, vif.mon_cb.req.sid))

    item = hpdcache_cri_req_item::type_id::create("observed_request");
    item.is_response  = 1'b0;
    item.op           = vif.mon_cb.req.op;
    item.data         = vif.mon_cb.req.wdata;
    item.be           = vif.mon_cb.req.be;
    item.size         = vif.mon_cb.req.size;
    item.sid          = vif.mon_cb.req.sid;
    item.tid          = vif.mon_cb.req.tid;
    item.need_rsp     = vif.mon_cb.req.need_rsp;
    item.phys_indexed = vif.mon_cb.req.phys_indexed;
    item.abort        = 1'b0;

    if (item.phys_indexed) begin
      item.addr = request_address(vif.mon_cb.req);
      item.pma  = vif.mon_cb.req.pma;
    end else begin
      item.addr = '0;
      item.addr[HPDCACHE_CFG.reqOffsetWidth-1:0] = vif.mon_cb.req.addr_offset;
      observed_vipt_requests++;
    end
    pending_requests.push_back(item);
  endfunction

  protected function void complete_request();
    hpdcache_cri_req_item item;

    if (pending_requests.size() == 0)
      return;
    item = pending_requests.pop_front();
    if (!item.phys_indexed) begin
      item.addr = {vif.mon_cb.req_tag, address_offset(item.addr)};
      item.pma = vif.mon_cb.req_pma;
      item.abort = vif.mon_cb.req_abort;
    end
    publish_request(item);
  endfunction

  protected function hpdcache_cri_item request_transaction(
    hpdcache_cri_req_item request
  );
    hpdcache_cri_item item;

    item = hpdcache_cri_item::type_id::create("cri_request_transaction");
    item.copy(request);
    item.is_response = 1'b0;
    item.error = 1'b0;
    item.aborted = 1'b0;
    item.response_data = '0;
    return item;
  endfunction

  protected function void publish_request(hpdcache_cri_req_item item);
    hpdcache_cri_item transaction;
    transaction_key_t transaction_key;

    observed_requests++;
    if (item.abort)
      observed_aborts++;

    transaction = request_transaction(item);
    req_ap.write(item);
    if (!item.need_rsp) begin
      cri_ap.write(transaction);
      return;
    end

    transaction_key = {item.sid, item.tid};
    if (pending_transactions.exists(transaction_key)) begin
      `uvm_error("HPDCACHE_CHK_CRI", $sformatf(
        "duplicate pending request SID %0d TID %0d",
        item.sid, item.tid))
      return;
    end
    pending_transactions[transaction_key] = transaction;
  endfunction

  protected function void sample_response();
    hpdcache_cri_resp_item item;
    hpdcache_cri_item transaction;
    transaction_key_t transaction_key;

    if (vif.mon_cb.rsp.sid !== hpdcache_req_sid_t'(cfg.requester_id))
      `uvm_error("HPDCACHE_CHK_CRI", $sformatf(
        "response on requester port %0d has SID %0d",
        cfg.requester_id, vif.mon_cb.rsp.sid))

    item = hpdcache_cri_resp_item::type_id::create("observed_response");
    item.is_response  = 1'b1;
    item.data         = vif.mon_cb.rsp.rdata;
    item.response_data = vif.mon_cb.rsp.rdata;
    item.sid          = vif.mon_cb.rsp.sid;
    item.tid          = vif.mon_cb.rsp.tid;
    item.error        = vif.mon_cb.rsp.error;
    item.aborted      = vif.mon_cb.rsp.aborted;
    observed_responses++;

    resp_ap.write(item);

    transaction_key = {item.sid, item.tid};
    if (!pending_transactions.exists(transaction_key)) begin
      `uvm_error("HPDCACHE_CHK_CRI", $sformatf(
        "response SID %0d TID %0d has no pending request",
        item.sid, item.tid))
      return;
    end

    transaction = pending_transactions[transaction_key];
    transaction.is_response = 1'b1;
    transaction.error = item.error;
    transaction.aborted = item.aborted;
    transaction.response_data = item.data;
    cri_ap.write(transaction);
    pending_transactions.delete(transaction_key);
  endfunction

  function automatic bit is_idle();
    return pending_requests.size() == 0 && pending_transactions.num() == 0;
  endfunction

  function void reset_state();
    pending_requests.delete();
    pending_transactions.delete();
  endfunction

  virtual function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (pending_requests.size() != 0 || pending_transactions.num() != 0)
      `uvm_error("HPDCACHE_CHK_CRI", $sformatf(
        "CRI monitor ended with pending requests=%0d transactions=%0d",
        pending_requests.size(), pending_transactions.num()))
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("HPDCACHE_RPT_TRAFFIC_CRI", $sformatf(
      "requester=%0d active=%0d requests=%0d vipt=%0d aborts=%0d responses=%0d",
      cfg.requester_id, cfg.active,
      observed_requests, observed_vipt_requests, observed_aborts,
      observed_responses), UVM_NONE)
  endfunction
endclass
