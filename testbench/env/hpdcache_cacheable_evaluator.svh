`uvm_analysis_imp_decl(_cacheable_actual)
`uvm_analysis_imp_decl(_cacheable_expected)
class hpdcache_cacheable_evaluator extends uvm_component;
  `uvm_component_utils(hpdcache_cacheable_evaluator)

  uvm_analysis_imp_cacheable_actual #(
    hpdcache_cri_resp_item, hpdcache_cacheable_evaluator
  ) actual_imp;
  uvm_analysis_imp_cacheable_expected #(
    hpdcache_cri_item, hpdcache_cacheable_evaluator
  ) expected_imp;

  localparam int unsigned SID_W = $bits(hpdcache_req_sid_t);
  localparam int unsigned TID_W = $bits(hpdcache_req_tid_t);
  typedef bit [SID_W+TID_W-1:0] key_t;

  hpdcache_pma_config pma_cfg;
  hpdcache_cri_resp_item actual_by_key[key_t][$];
  hpdcache_cri_item expected_by_key[key_t][$];
  int unsigned received_actual;
  int unsigned received_expected;
  int unsigned checked_responses;
  int unsigned skipped_uncacheable;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    actual_imp = new("actual_imp", this);
    expected_imp = new("expected_imp", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(hpdcache_pma_config)::get(
          this, "", "pma_cfg", pma_cfg) || pma_cfg == null)
      `uvm_fatal(get_type_name(), "hpdcache_pma_config was not configured")
  endfunction

  function automatic key_t key(hpdcache_cri_item t);
    return {t.sid, t.tid};
  endfunction

  function automatic bit is_idle();
    return actual_by_key.num() == 0 && expected_by_key.num() == 0;
  endfunction

  virtual task reset_phase(uvm_phase phase);
    super.reset_phase(phase);
    actual_by_key.delete();
    expected_by_key.delete();
  endtask

  function void write_cacheable_actual(hpdcache_cri_resp_item t);
    key_t transaction_key;
    hpdcache_cri_resp_item snapshot;

    if (!$cast(snapshot, t.clone()))
      `uvm_fatal(get_type_name(), "failed to clone actual response")
    received_actual++;
    transaction_key = key(snapshot);
    actual_by_key[transaction_key].push_back(snapshot);
    try_compare(transaction_key);
  endfunction

  function void write_cacheable_expected(hpdcache_cri_item t);
    key_t transaction_key;
    hpdcache_cri_item snapshot;

    if (!$cast(snapshot, t.clone()))
      `uvm_fatal(get_type_name(), "failed to clone expected response")
    received_expected++;
    transaction_key = key(snapshot);
    expected_by_key[transaction_key].push_back(snapshot);
    try_compare(transaction_key);
  endfunction

  function void try_compare(key_t transaction_key);
    hpdcache_cri_item actual;
    hpdcache_cri_item expected;

    if (!actual_by_key.exists(transaction_key) ||
        !expected_by_key.exists(transaction_key))
      return;
    while (actual_by_key[transaction_key].size() != 0 &&
           expected_by_key[transaction_key].size() != 0) begin
      actual = actual_by_key[transaction_key].pop_front();
      expected = expected_by_key[transaction_key].pop_front();

      if (!is_cmo(expected.op) && pma_cfg.is_uncacheable(expected.addr)) begin
        skipped_uncacheable++;
        continue;
      end

      checked_responses++;
      if (actual.error !== expected.error)
        `uvm_error("HPDCACHE_CHK_CACHEABLE", $sformatf(
          "response error mismatch sid=%0d tid=%0d op=%s addr=0x%0h expected=%0b actual=%0b",
          actual.sid, actual.tid, expected.op.name(), expected.addr,
          expected.error, actual.error))
      if (actual.aborted !== expected.aborted)
        `uvm_error("HPDCACHE_CHK_CACHEABLE", $sformatf(
          "response abort mismatch sid=%0d tid=%0d op=%s addr=0x%0h expected=%0b actual=%0b",
          actual.sid, actual.tid, expected.op.name(), expected.addr,
          expected.aborted, actual.aborted))
      if (!actual.error && !actual.aborted &&
          (expected.op == HPDCACHE_REQ_LOAD || is_amo(expected.op))) begin
        for (int i = 0; i < $bits(expected.data_valid[0]); i++) begin
          if (expected.data_valid[0][i] &&
              actual.data[0][i*8 +: 8] !== expected.data[0][i*8 +: 8])
            `uvm_error("HPDCACHE_CHK_CACHEABLE", $sformatf(
              "%s data mismatch addr=0x%0h byte=%0d expected=0x%02h actual=0x%02h",
              expected.op.name(), expected.addr, i,
              expected.data[0][i*8 +: 8],
              actual.data[0][i*8 +: 8]))
        end
      end
    end
    if (actual_by_key[transaction_key].size() == 0)
      actual_by_key.delete(transaction_key);
    if (expected_by_key[transaction_key].size() == 0)
      expected_by_key.delete(transaction_key);
  endfunction

  virtual function void check_phase(uvm_phase phase);
    key_t transaction_key;
    hpdcache_cri_item item;

    super.check_phase(phase);
    foreach (actual_by_key[transaction_key]) begin
      for (int i = 0; i < actual_by_key[transaction_key].size(); i++) begin
        item = actual_by_key[transaction_key][i];
        `uvm_error("HPDCACHE_CHK_CACHEABLE", $sformatf(
          "unmatched actual key=0x%0h index=%0d (sid=%0d tid=%0d)",
          transaction_key, i, item.sid, item.tid))
      end
    end
    foreach (expected_by_key[transaction_key]) begin
      for (int i = 0; i < expected_by_key[transaction_key].size(); i++) begin
        item = expected_by_key[transaction_key][i];
        `uvm_error("HPDCACHE_CHK_CACHEABLE", $sformatf(
          "unmatched expected key=0x%0h index=%0d (sid=%0d tid=%0d)",
          transaction_key, i, item.sid, item.tid))
      end
    end
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("HPDCACHE_RPT_CHECK_CACHEABLE", $sformatf(
      "actual=%0d expected=%0d checked=%0d skipped=%0d",
      received_actual, received_expected, checked_responses,
      skipped_uncacheable), UVM_NONE)
  endfunction
endclass
