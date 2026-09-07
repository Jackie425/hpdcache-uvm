class hpdcache_base_seq extends uvm_sequence #(hpdcache_cri_item);
  `uvm_object_utils(hpdcache_base_seq)
  `uvm_declare_p_sequencer(hpdcache_cri_sequencer)

  hpdcache_cri_item req;
  hpdcache_cri_item rsp;

  // Disable this only when a caller will provide a legal address and PMA.
  bit use_pma_region;

  protected hpdcache_req_tid_t tid;

  function new(string name = "hpdcache_base_seq");
    super.new(name);
    use_pma_region = 1'b1;
  endfunction

  virtual task pre_start();
    int unsigned selected_region;

    super.pre_start();
    if (p_sequencer == null || p_sequencer.cfg == null)
      `uvm_fatal(get_type_name(), "sequencer has no hpdcache_cri_agent_config")
    if (use_pma_region &&
        (p_sequencer.cfg.pma_cfg == null ||
         p_sequencer.cfg.pma_cfg.num_regions() == 0))
      `uvm_fatal(get_type_name(), "sequencer has no configured PMA region")

    if (use_pma_region) begin
      if (!std::randomize(selected_region) with {
        selected_region < p_sequencer.cfg.pma_cfg.num_regions();
      })
        `uvm_fatal(get_type_name(), "failed to randomize the PMA region")
    end

    p_sequencer.acquire_tid(tid);
    req = hpdcache_cri_item::type_id::create("req");
    if (use_pma_region) begin
      req.use_pma_region = 1'b1;
      req.pma_region_base = p_sequencer.cfg.pma_cfg.region_base(
        selected_region
      );
      req.pma_region_last = p_sequencer.cfg.pma_cfg.region_last(
        selected_region
      );
      req.pma_region_uncacheable =
        p_sequencer.cfg.pma_cfg.region_is_uncacheable(selected_region);
    end
    req.sid = p_sequencer.cfg.requester_id;
    req.tid = tid;
  endtask

  virtual task post_start();
    get_response(rsp);
    if (rsp == null)
      `uvm_error("HPDCACHE_CHK_SEQUENCE", "received a null driver response")
    else begin
      if (rsp.sid != p_sequencer.cfg.requester_id)
        `uvm_error("HPDCACHE_CHK_SEQUENCE", $sformatf(
          "response SID %0d does not match requester %0d",
          rsp.sid, p_sequencer.cfg.requester_id))
      if (rsp.tid != tid)
        `uvm_error("HPDCACHE_CHK_SEQUENCE", $sformatf(
          "response TID %0d does not match allocated TID %0d",
          int'(rsp.tid), int'(tid)))
    end
    p_sequencer.release_tid(tid);
    super.post_start();
  endtask

  virtual task body();
    `uvm_fatal(get_type_name(), "hpdcache_base_seq must be extended")
  endtask
endclass
