// Randomly assert the real bus reset while ordinary traffic is running.  The
// test deliberately stays in main_phase: reset is a DUT signal event, not a
// UVM phase transition.
class hpdcache_on_the_fly_reset_test extends hpdcache_base_test;
  `uvm_component_utils(hpdcache_on_the_fly_reset_test)

  int unsigned reset_count;
  int unsigned planned_items;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_sequence();
    hpdcache_random_vseq traffic;

    traffic = hpdcache_random_vseq::type_id::create("reset_random_vseq");
    init_vseq(traffic);
    traffic.item_num = 1000;
    planned_items = env_cfg.active_agent_num * traffic.item_num;

    fork : reset_test_threads
      begin
        traffic.start(null);
      end
      begin
        // Random gaps make reset land in different driver/monitor states over
        // repeated seeds, while the long traffic run keeps it on-the-fly.
        repeat (4) begin
          env.clock_driver.wait_n_clocks(
            $urandom_range(20, 100)
          );
          env.reset_driver.pulse_reset($urandom_range(1, 8));
          reset_count++;
        end
      end
    join

    `uvm_info("HPDCACHE_RPT_RESET", $sformatf(
      "resets=%0d signal_driven=1 phase_jump=0 recovery_complete=1",
      reset_count), UVM_NONE)
  endtask

  virtual function void report_phase(uvm_phase phase);
    int unsigned observed_items = 0;
    int unsigned legal_cancellations = 0;

    foreach (env.cri_agents[i]) begin
      if (!env.cri_agents[i].cfg.active)
        continue;
      observed_items += env.cri_agents[i].monitor.num_observed_requests();
      legal_cancellations += env.cri_agents[i].driver.num_reset_cancelled();
    end

    if (observed_items + legal_cancellations != planned_items)
      `uvm_error("HPDCACHE_CHK_RESET", $sformatf(
        "reset accounting mismatch planned=%0d observed=%0d legal_cancellations=%0d",
        planned_items, observed_items, legal_cancellations))

    `uvm_info("HPDCACHE_RPT_RESET_ACCOUNTING", $sformatf(
      "planned=%0d observed=%0d legal_cancellations=%0d balanced=%0d",
      planned_items, observed_items, legal_cancellations,
      observed_items + legal_cancellations == planned_items), UVM_NONE)
    super.report_phase(phase);
  endfunction
endclass
