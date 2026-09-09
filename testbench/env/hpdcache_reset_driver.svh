// Runtime reset driver used by the HPDcache environment.
//
// The generic cv_dv_utils reset driver contains a legacy main_phase hook that
// can phase-jump when emit_assert_reset() is called.  Runtime reset in this
// environment is a signal event, so keep the driver phase independent and
// expose an explicit, cycle-bounded pulse API instead.
class hpdcache_reset_driver extends reset_driver_c #(1'b1, 8, 0);
  `uvm_component_utils(hpdcache_reset_driver)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    // Deliberately empty: runtime reset must not change the UVM phase.
  endtask

  virtual task pulse_reset(int unsigned hold_cycles);
    if (hold_cycles == 0)
      return;

    // xrtl_reset_vif samples this counter on the clock, so the reset pulse is
    // generated through the same DUT-facing interface as power-on reset.
    m_v_reset_vif.assert_reset(hold_cycles);
    do @(posedge m_v_reset_vif.clk);
    while (m_v_reset_vif.reset_n !== 1'b1);
  endtask
endclass
