class hpdcache_env extends uvm_env;
  `uvm_component_utils(hpdcache_env)

  hpdcache_env_config cfg;
  hpdcache_cri_agent cri_agents[NREQUESTERS];
  hpdcache_cmi_agent cmi_agent;
  hpdcache_scoreboard scoreboard;
  memory_response_model #(MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH) mem_rsp_model;
  axi2mem #(MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH, 1) axi_bridge;
  memory_rsp_cfg mem_cfg;
  clock_driver_c clock_driver;
  clock_config_c clock_cfg;
  reset_driver_c #(1'b1, 8, 0) reset_driver;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(hpdcache_env_config)::get(this, "", "cfg", cfg) ||
        cfg == null)
      `uvm_fatal(get_type_name(), "hpdcache_env_config was not configured")
    cfg.validate();

    uvm_config_db#(hpdcache_pma_config)::set(
      this, "scoreboard", "pma_cfg", cfg.pma_cfg
    );
    scoreboard = hpdcache_scoreboard::type_id::create("scoreboard", this);
    cmi_agent = hpdcache_cmi_agent::type_id::create("cmi_agent", this);
    clock_driver = clock_driver_c::type_id::create("clock_driver", this);
    clock_cfg = clock_config_c::type_id::create("clock_cfg", this);
    clock_driver.m_clk_cfg = clock_cfg;
    reset_driver = reset_driver_c#(1'b1, 8, 0)::type_id::create(
      "hpdcache_reset_driver", this
    );

    for (int unsigned i = 0; i < NREQUESTERS; i++) begin
      uvm_config_db#(hpdcache_cri_agent_config)::set(
        this, $sformatf("cri_agent_%0d", i), "cfg", cfg.cri_agent_cfgs[i]
      );
      cri_agents[i] = hpdcache_cri_agent::type_id::create(
        $sformatf("cri_agent_%0d", i), this
      );
    end

    mem_cfg = cfg.mem_cfg;

    mem_rsp_model = memory_response_model#(
      MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH
    )::type_id::create("mem_rsp_model", this);
    axi_bridge = axi2mem#(
      MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH, 1
    )::type_id::create("axi2mem_req", this);
  endfunction

  function void end_of_elaboration_phase(uvm_phase phase);
    super.end_of_elaboration_phase(phase);
    if (!clock_cfg.randomize() with {
      m_starting_signal_level == 1'b0;
      m_clock_frequency == 100;
      m_duty_cycle == 50;
    })
      `uvm_fatal(get_type_name(), "Clock configuration randomization failed")
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    foreach (cri_agents[i])
      cri_agents[i].monitor.req_ap.connect(scoreboard.cri_req_export);
    foreach (cri_agents[i])
      cri_agents[i].monitor.resp_ap.connect(scoreboard.cri_resp_export);
    foreach (cri_agents[i])
      cri_agents[i].monitor.cri_ap.connect(scoreboard.cri_export);
    cmi_agent.monitor.read_ap.connect(scoreboard.cmi_read_export);
    cmi_agent.monitor.write_ap.connect(scoreboard.cmi_write_export);
    mem_rsp_model.m_rsp_cfg = mem_cfg;
    mem_rsp_model.ap_mem_rd_rsp.connect(
      scoreboard.memory_read_response_export
    );
  endfunction

  function automatic bit is_drained();
    if (!scoreboard.is_idle())
      return 1'b0;
    if (!cmi_agent.is_idle())
      return 1'b0;
    foreach (cri_agents[i]) begin
      if (!cri_agents[i].is_idle())
        return 1'b0;
    end
    return 1'b1;
  endfunction

  function automatic string drain_status();
    string status;
    status = {scoreboard.drain_status(), $sformatf(
      " cmi_agent_idle=%0b", cmi_agent.is_idle())};
    foreach (cri_agents[i]) begin
      if (cri_agents[i].cfg.active)
        status = {status, $sformatf(
          " cri_agent_%0d_monitor_idle=%0b cri_agent_%0d_driver_idle=%0b cri_agent_%0d_outstanding_tids=%0d",
          i, cri_agents[i].monitor.is_idle(), i,
          cri_agents[i].driver.is_idle(), i,
          cri_agents[i].sequencer.num_outstanding())};
    end
    return status;
  endfunction

  task wait_for_drain(time timeout);
    if (is_drained())
      return;

    fork : drain_or_timeout
      begin
        do
          clock_driver.m_v_clock_vif.wait_n_clocks(1);
        while (!is_drained());
      end
      begin
        #(timeout);
      end
    join_any
    disable drain_or_timeout;
  endtask

  virtual function void report_phase(uvm_phase phase);
    int unsigned driver_outstanding = 0;
    int unsigned sequencer_outstanding = 0;

    super.report_phase(phase);
    foreach (cri_agents[i]) begin
      if (!cri_agents[i].cfg.active)
        continue;
      driver_outstanding += cri_agents[i].driver.num_outstanding();
      sequencer_outstanding += cri_agents[i].sequencer.num_outstanding();
    end
    `uvm_info("HPDCACHE_RPT_DRAIN", $sformatf(
      "drained=%0d scoreboard_idle=%0d cmi_idle=%0d driver_outstanding=%0d sequencer_outstanding=%0d",
      is_drained(), scoreboard.is_idle(), cmi_agent.is_idle(),
      driver_outstanding, sequencer_outstanding), UVM_NONE)
  endfunction

endclass
