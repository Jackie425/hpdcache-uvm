class hpdcache_cri_agent extends uvm_agent;
  `uvm_component_utils(hpdcache_cri_agent)

  hpdcache_cri_agent_config cfg;
  hpdcache_pma_config   pma_cfg;
  hpdcache_cri_sequencer    sequencer;
  hpdcache_cri_driver       driver;
  hpdcache_cri_monitor      monitor;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(hpdcache_cri_agent_config)::get(this, "", "cfg", cfg) ||
        cfg == null)
      `uvm_fatal(get_type_name(), "hpdcache_cri_agent_config was not configured")
    cfg.validate();
    pma_cfg = cfg.pma_cfg;

    uvm_config_db#(hpdcache_cri_agent_config)::set(
      this, "monitor", "cfg", cfg
    );
    monitor = hpdcache_cri_monitor::type_id::create("monitor", this);
    if (cfg.active) begin
      uvm_config_db#(hpdcache_cri_agent_config)::set(this, "sequencer", "cfg", cfg);
      uvm_config_db#(hpdcache_cri_agent_config)::set(this, "driver", "cfg", cfg);
      sequencer = hpdcache_cri_sequencer::type_id::create("sequencer", this);
      driver    = hpdcache_cri_driver::type_id::create("driver", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (cfg.active)
      driver.seq_item_port.connect(sequencer.seq_item_export);
  endfunction

  virtual task reset_phase(uvm_phase phase);
    super.reset_phase(phase);
    if (cfg.active) begin
      // A UVM reset phase terminates the old stimulus epoch.  Remove requests
      // still owned by the sequencer, then discard driver-held contexts before
      // making every protocol TID available to the next epoch.
      sequencer.stop_sequences();
      driver.reset_state();
      sequencer.reset_tid_pool();
    end
  endtask

  function automatic bit is_idle();
    return monitor.is_idle() &&
           (!cfg.active || (driver.is_idle() && sequencer.is_idle()));
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    if (cfg.active)
      `uvm_info(get_type_name(), $sformatf(
        "requester=%0d driver_outstanding=%0d sequencer_outstanding=%0d",
        cfg.requester_id, driver.num_outstanding(),
        sequencer.num_outstanding()), UVM_LOW)
  endfunction
endclass
