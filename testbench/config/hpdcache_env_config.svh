class hpdcache_env_config extends uvm_object;
  `uvm_object_utils(hpdcache_env_config)

  hpdcache_cri_agent_config cri_agent_cfgs[NREQUESTERS];
  hpdcache_pma_config pma_cfg;
  memory_rsp_cfg mem_cfg;
  int unsigned active_agent_num =
    NREQUESTERS - (HAS_PREFETCHER ? 1 : 0);

  function new(string name = "hpdcache_env_config");
    super.new(name);
  endfunction

  function void validate();
    if (active_agent_num > NREQUESTERS - (HAS_PREFETCHER ? 1 : 0))
      `uvm_fatal(get_type_name(), $sformatf(
        "active_agent_num %0d exceeds the %0d testbench requesters",
        active_agent_num, NREQUESTERS - (HAS_PREFETCHER ? 1 : 0)))
    if (pma_cfg == null)
      `uvm_fatal(get_type_name(), "pma_cfg was not configured")
    pma_cfg.validate();

    if (mem_cfg == null)
      `uvm_fatal(get_type_name(), "mem_cfg was not configured")
    foreach (cri_agent_cfgs[i]) begin
      if (cri_agent_cfgs[i] == null)
        `uvm_fatal(get_type_name(), $sformatf(
          "cri_agent_cfgs[%0d] was not configured", i))
      if (cri_agent_cfgs[i].pma_cfg != pma_cfg)
        `uvm_fatal(get_type_name(), $sformatf(
          "cri_agent_cfgs[%0d] does not share the environment PMA config", i))
      cri_agent_cfgs[i].validate();
    end
  endfunction
endclass
