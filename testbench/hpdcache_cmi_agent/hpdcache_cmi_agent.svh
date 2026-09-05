class hpdcache_cmi_agent extends uvm_agent;
  `uvm_component_utils(hpdcache_cmi_agent)

  hpdcache_cmi_monitor monitor;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    monitor = hpdcache_cmi_monitor::type_id::create("monitor", this);
  endfunction

  function automatic bit is_idle();
    return monitor.is_idle();
  endfunction
endclass
