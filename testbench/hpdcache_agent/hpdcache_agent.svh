class hpdcache_agent extends uvm_agent;
  `uvm_component_utils(hpdcache_agent)

  hpdcache_agent_config cfg;
  hpdcache_sequencer    sequencer;
  hpdcache_driver       driver;
  hpdcache_monitor      monitor;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(hpdcache_agent_config)::get(this, "", "cfg", cfg) ||
        cfg == null)
      `uvm_fatal(get_type_name(), "hpdcache_agent_config was not configured")
    cfg.validate();

    monitor = hpdcache_monitor::type_id::create("monitor", this);
    monitor.cfg = cfg;
    if (cfg.active) begin
      sequencer = hpdcache_sequencer::type_id::create("sequencer", this);
      sequencer.cfg = cfg;
      driver    = hpdcache_driver::type_id::create("driver", this);
      driver.cfg = cfg;
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
      cfg.tid_manager.reset_pool();
    end
  endtask

  function automatic bit is_idle();
    return !cfg.active || (driver.is_idle() && cfg.tid_manager.is_idle());
  endfunction
endclass
