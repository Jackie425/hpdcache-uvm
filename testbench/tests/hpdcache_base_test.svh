class hpdcache_base_test extends uvm_test;
  `uvm_component_utils(hpdcache_base_test)

  hpdcache_env env;
  hpdcache_env_config env_cfg;
  time drain_timeout = 1ms;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    create_env_config();
    foreach (env_cfg.cri_agent_cfgs[i])
      env_cfg.cri_agent_cfgs[i].active = i < env_cfg.active_agent_num;
    uvm_config_db#(hpdcache_env_config)::set(this, "env", "cfg", env_cfg);
    env = hpdcache_env::type_id::create("env", this);
  endfunction

  protected function void create_env_config();
    env_cfg = hpdcache_env_config::type_id::create("env_cfg");
    env_cfg.pma_cfg = hpdcache_pma_config::type_id::create("pma_cfg");
    // PMA regions define address-based cacheability; policy hints belong to items.
    env_cfg.pma_cfg.add_region(
      hpdcache_req_addr_t'(56'h00000080000000),
      hpdcache_req_addr_t'(56'h00000080002fff),
      HPDCACHE_CACHEABLE
    );
    env_cfg.pma_cfg.add_region(
      hpdcache_req_addr_t'(56'h00000080003000),
      hpdcache_req_addr_t'(56'h00000080003fff),
      HPDCACHE_UNCACHEABLE
    );

    foreach (env_cfg.cri_agent_cfgs[i]) begin
      env_cfg.cri_agent_cfgs[i] = hpdcache_cri_agent_config::type_id::create(
        $sformatf("cri_agent_%0d_cfg", i)
      );
      env_cfg.cri_agent_cfgs[i].requester_id = i;
      env_cfg.cri_agent_cfgs[i].pma_cfg = env_cfg.pma_cfg;
    end
    env_cfg.mem_cfg = memory_rsp_cfg::type_id::create("mem_cfg");
    env_cfg.mem_cfg.m_enable = 1'b1;
    env_cfg.mem_cfg.rsp_order = IN_ORDER_RSP;
    env_cfg.mem_cfg.rsp_mode = ZERO_DELAY_RSP;
    env_cfg.mem_cfg.inter_data_cycle_fixed_delay = 0;
    env_cfg.mem_cfg.insert_wr_error = 1'b0;
    env_cfg.mem_cfg.insert_rd_error = 1'b0;
    env_cfg.mem_cfg.insert_amo_wr_error = 1'b0;
    env_cfg.mem_cfg.insert_amo_rd_error = 1'b0;
    env_cfg.mem_cfg.insert_wr_exclusive_fail = 1'b0;
    env_cfg.mem_cfg.insert_rd_exclusive_fail = 1'b0;
    env_cfg.mem_cfg.unsolicited_rsp = 1'b0;
    env_cfg.mem_cfg.m_bp = NEVER;
  endfunction

  protected function void init_vseq(hpdcache_base_vseq vseq);
    if (vseq == null)
      `uvm_fatal(get_type_name(), "cannot initialize a null virtual sequence")

    vseq.cri_sequencers.delete();
    foreach (env.cri_agents[i]) begin
      if (env_cfg.cri_agent_cfgs[i].active)
        vseq.cri_sequencers.push_back(env.cri_agents[i].sequencer);
    end
  endfunction

  virtual task run_test_sequence();
    `uvm_fatal(get_type_name(), "hpdcache_base_test must implement run_test_sequence()")
  endtask

  task main_phase(uvm_phase phase);
    phase.raise_objection(this, "running test stimulus");
    run_test_sequence();
    env.wait_for_drain(drain_timeout);
    if (!env.is_drained())
      `uvm_error("HPDCACHE_CHK_DRAIN", $sformatf(
        "environment did not drain within %0t (%s)",
        drain_timeout, env.drain_status()))
    phase.drop_objection(this, "test stimulus and drain completed");
  endtask

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("HPDCACHE_RPT_META", $sformatf(
      "schema=1 test=%s", get_type_name()), UVM_NONE)
    `uvm_info("HPDCACHE_RPT_CONFIG", $sformatf(
      "active_requesters=%0d total_requesters=%0d has_prefetcher=%0d",
      env_cfg.active_agent_num, NREQUESTERS, HAS_PREFETCHER), UVM_NONE)
    `uvm_info("HPDCACHE_RPT_END", "complete=1", UVM_NONE)
  endfunction
endclass
