class hpdcache_env extends uvm_env;
  `uvm_component_utils(hpdcache_env)

  localparam int unsigned NUM_CORE_REQUESTERS = NREQUESTERS - 1;

  hpdcache_agent        agents[NREQUESTERS];
  hpdcache_agent_config agent_configs[NREQUESTERS];
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
    scoreboard = hpdcache_scoreboard::type_id::create("scoreboard", this);

    clock_driver = clock_driver_c::type_id::create("clock_driver", this);
    clock_cfg = clock_config_c::type_id::create("clock_cfg", this);
    clock_driver.m_clk_cfg = clock_cfg;
    reset_driver = reset_driver_c#(1'b1, 8, 0)::type_id::create(
      "hpdcache_reset_driver", this
    );

    for (int unsigned i = 0; i < NREQUESTERS; i++) begin
      agent_configs[i] = hpdcache_agent_config::type_id::create(
        $sformatf("agent_%0d_cfg", i)
      );
      agent_configs[i].active = i < NUM_CORE_REQUESTERS;
      agent_configs[i].requester_id = i;
      agents[i] = hpdcache_agent::type_id::create(
        $sformatf("agent_%0d", i), this
      );
      uvm_config_db#(hpdcache_agent_config)::set(
        agents[i], "", "cfg", agent_configs[i]
      );
    end

    mem_cfg = memory_rsp_cfg::type_id::create("mem_cfg");
    mem_cfg.m_enable = 1'b1;
    mem_cfg.rsp_order = IN_ORDER_RSP;
    mem_cfg.rsp_mode = ZERO_DELAY_RSP;
    mem_cfg.inter_data_cycle_fixed_delay = 0;
    mem_cfg.insert_wr_error = 1'b0;
    mem_cfg.insert_rd_error = 1'b0;
    mem_cfg.insert_amo_wr_error = 1'b0;
    mem_cfg.insert_amo_rd_error = 1'b0;
    mem_cfg.insert_wr_exclusive_fail = 1'b0;
    mem_cfg.insert_rd_exclusive_fail = 1'b0;
    mem_cfg.unsolicited_rsp = 1'b0;
    mem_cfg.m_bp = NEVER;

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
    foreach (agents[i])
      agents[i].monitor.ap.connect(scoreboard.request_export);
    foreach (agents[i])
      agents[i].monitor.ap.connect(scoreboard.actual_export);
    mem_rsp_model.m_rsp_cfg = mem_cfg;
    mem_rsp_model.ap_mem_rd_rsp.connect(scoreboard.memory_response_export);
  endfunction

  function automatic bit is_drained();
    if (!scoreboard.is_idle())
      return 1'b0;
    foreach (agents[i]) begin
      if (!agents[i].is_idle())
        return 1'b0;
    end
    return 1'b1;
  endfunction

  function automatic string drain_status();
    string status;
    status = scoreboard.drain_status();
    foreach (agents[i]) begin
      if (agents[i].cfg.active)
        status = {status, $sformatf(
          " agent_%0d_driver_idle=%0b agent_%0d_outstanding_tids=%0d",
          i, agents[i].driver.is_idle(), i,
          agents[i].cfg.tid_manager.num_outstanding())};
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

endclass
