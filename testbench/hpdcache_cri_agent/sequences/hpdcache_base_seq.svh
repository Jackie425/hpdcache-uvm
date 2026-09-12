typedef struct {
  bit                  valid;
  hpdcache_req_addr_t  base;
  hpdcache_req_addr_t  last;
} hpdcache_addr_range_t;

class hpdcache_base_seq extends uvm_sequence #(hpdcache_cri_item);
  `uvm_object_utils(hpdcache_base_seq)
  `uvm_declare_p_sequencer(hpdcache_cri_sequencer)

  hpdcache_cri_item req;
  hpdcache_cri_item rsp;

  // Disable this when the caller provides the complete request attributes.
  bit constrain_addr_range;
  hpdcache_addr_range_t address_range;

  protected hpdcache_req_tid_t tid;

  function new(string name = "hpdcache_base_seq");
    super.new(name);
    constrain_addr_range = 1'b1;
    address_range = '{default: '0};
  endfunction

  virtual task pre_start();
    hpdcache_pma_config::pma_region_t pma_region;
    hpdcache_addr_range_t effective_addr_range;

    super.pre_start();
    if (p_sequencer == null || p_sequencer.cfg == null)
      `uvm_fatal(get_type_name(), "sequencer has no hpdcache_cri_agent_config")

    if (constrain_addr_range) begin
      if (p_sequencer.cfg.pma_cfg == null)
        `uvm_fatal(get_type_name(), "sequencer has no PMA configuration")
      if (address_range.valid) begin
        if (!p_sequencer.cfg.pma_cfg.find_pma_region(
              address_range.base, pma_region) ||
            address_range.last < address_range.base ||
            address_range.last > pma_region.last)
          `uvm_fatal(get_type_name(),
            "address range crosses a configured PMA region boundary")
        effective_addr_range = address_range;
      end else begin
        pma_region = p_sequencer.cfg.pma_cfg.random_pma_region();
        effective_addr_range = '{
          valid: 1'b1,
          base:  pma_region.base,
          last:  pma_region.last
        };
      end
    end

    p_sequencer.acquire_tid(tid);
    req = hpdcache_cri_item::type_id::create("req");
    if (constrain_addr_range) begin
      req.constrain_addr_range = 1'b1;
      req.addr_range_base = effective_addr_range.base;
      req.addr_range_last = effective_addr_range.last;
      req.pma_uncacheable =
        pma_region.cacheability == HPDCACHE_UNCACHEABLE;
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
