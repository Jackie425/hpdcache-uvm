// The sequencer exposes its agent configuration to sequences started on it.
class hpdcache_sequencer extends uvm_sequencer #(hpdcache_item);
  `uvm_component_utils(hpdcache_sequencer)

  hpdcache_agent_config cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (cfg == null)
      `uvm_fatal(get_type_name(), "agent did not assign hpdcache_agent_config")
  endfunction
endclass
