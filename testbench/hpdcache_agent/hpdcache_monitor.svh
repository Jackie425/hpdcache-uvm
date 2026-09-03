class hpdcache_monitor extends uvm_monitor;
  `uvm_component_utils(hpdcache_monitor)

  virtual hpdcache_if vif;
  hpdcache_agent_config cfg;
  uvm_analysis_port #(hpdcache_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual hpdcache_if)::get(this, "", "vif", vif))
      `uvm_fatal(get_type_name(), "hpdcache_if was not configured")
    if (cfg == null)
      `uvm_fatal(get_type_name(), "agent did not assign hpdcache_agent_config")
  endfunction

  virtual task run_phase(uvm_phase phase);
    super.run_phase(phase);
    monitor_requests_and_responses();
  endtask

  task monitor_requests_and_responses();
    hpdcache_item item;
    forever begin
      @(vif.mon_cb);
      if (!vif.mon_cb.rst_ni)
        continue;

      if (vif.mon_cb.req_valid && vif.mon_cb.req_ready) begin
        if (vif.mon_cb.req.sid != cfg.requester_id)
          `uvm_error(get_type_name(), $sformatf(
            "request on requester port %0d has SID %0d",
            cfg.requester_id, vif.mon_cb.req.sid))
        item = hpdcache_item::type_id::create("observed_request");
        item.is_response  = 1'b0;
        item.op           = vif.mon_cb.req.op;
        item.addr         = request_address(vif.mon_cb.req);
        item.data         = vif.mon_cb.req.wdata;
        item.be           = vif.mon_cb.req.be;
        item.size         = vif.mon_cb.req.size;
        item.sid          = vif.mon_cb.req.sid;
        item.tid          = vif.mon_cb.req.tid;
        ap.write(item);
      end

      if (vif.mon_cb.rsp_valid) begin
        if (vif.mon_cb.rsp.sid != cfg.requester_id)
          `uvm_error(get_type_name(), $sformatf(
            "response on requester port %0d has SID %0d",
            cfg.requester_id, vif.mon_cb.rsp.sid))
        item = hpdcache_item::type_id::create("observed_response");
        item.is_response  = 1'b1;
        item.data         = vif.mon_cb.rsp.rdata;
        item.sid          = vif.mon_cb.rsp.sid;
        item.tid          = vif.mon_cb.rsp.tid;
        item.error        = vif.mon_cb.rsp.error;
        ap.write(item);
      end
    end
  endtask
endclass
