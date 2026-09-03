class hpdcache_random_test extends hpdcache_base_test;
  `uvm_component_utils(hpdcache_random_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_sequence();
    hpdcache_random_sequence seq;
    seq = hpdcache_random_sequence::type_id::create("seq");
    seq.start(env.agents[0].sequencer);
  endtask
endclass
