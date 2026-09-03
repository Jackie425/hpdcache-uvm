class hpdcache_base_test extends uvm_test;
  `uvm_component_utils(hpdcache_base_test)

  hpdcache_env env;
  time drain_timeout = 10us;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = hpdcache_env::type_id::create("env", this);
  endfunction

  virtual task run_test_sequence();
    `uvm_fatal(get_type_name(), "hpdcache_base_test must implement run_test_sequence()")
  endtask

  task main_phase(uvm_phase phase);
    phase.raise_objection(this, "running test stimulus");
    run_test_sequence();
    env.wait_for_drain(drain_timeout);
    if (!env.is_drained())
      `uvm_error("DRAIN_TIMEOUT", $sformatf(
        "environment did not drain within %0t (%s)",
        drain_timeout, env.drain_status()))
    phase.drop_objection(this, "test stimulus and drain completed");
  endtask
endclass
