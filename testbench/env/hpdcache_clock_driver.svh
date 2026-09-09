// HPDcache clock wrapper.  Keeping the clock driver as an environment-owned
// type makes the clock/reset stimulus boundary explicit and avoids exposing
// the vendor driver's implementation details in tests.
class hpdcache_clock_driver extends clock_driver_c;
  `uvm_component_utils(hpdcache_clock_driver)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task wait_n_clocks(int unsigned count);
    m_v_clock_vif.wait_n_clocks(count);
  endtask
endclass
