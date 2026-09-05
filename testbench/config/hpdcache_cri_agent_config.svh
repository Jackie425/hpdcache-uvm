class hpdcache_cri_agent_config extends uvm_object;
  `uvm_object_utils(hpdcache_cri_agent_config)

  bit active = 1'b1;
  int unsigned requester_id;
  hpdcache_pma_config pma_cfg;

  function new(string name = "hpdcache_cri_agent_config");
    super.new(name);
  endfunction

  function void validate();
    if (requester_id >= (1 << REQ_SRC_ID_WIDTH))
      `uvm_fatal(get_type_name(), $sformatf(
        "requester_id %0d does not fit in the %0d-bit SID",
        requester_id, REQ_SRC_ID_WIDTH))
    if (pma_cfg == null)
      `uvm_fatal(get_type_name(), "pma_cfg was not configured")
  endfunction
endclass
