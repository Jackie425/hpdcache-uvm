`uvm_analysis_imp_decl(_actual)
`uvm_analysis_imp_decl(_expected)
class hpdcache_evaluator extends uvm_component;
  `uvm_component_utils(hpdcache_evaluator)
  uvm_analysis_imp_actual #(hpdcache_item, hpdcache_evaluator) actual_imp;
  uvm_analysis_imp_expected #(hpdcache_item, hpdcache_evaluator) expected_imp;

  // A response is identified by the source ID and transaction ID carried on
  // the HPDcache interface.
  localparam int unsigned SID_W = $bits(hpdcache_req_sid_t);
  localparam int unsigned TID_W = $bits(hpdcache_req_tid_t);
  typedef bit [SID_W+TID_W-1:0] key_t;

  hpdcache_item actual_by_key[key_t][$];
  hpdcache_item expected_by_key[key_t][$];
  int unsigned checked_responses;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    actual_imp = new("actual_imp", this);
    expected_imp = new("expected_imp", this);
  endfunction

  function automatic key_t key(hpdcache_item t);
    return {t.sid, t.tid};
  endfunction

  function automatic bit is_idle();
    return (actual_by_key.num() == 0) &&
           (expected_by_key.num() == 0);
  endfunction

  virtual task reset_phase(uvm_phase phase);
    super.reset_phase(phase);
    actual_by_key.delete();
    expected_by_key.delete();
  endtask

  function void write_actual(hpdcache_item t);
    key_t transaction_key;
    // The core monitor publishes requests and responses on the same analysis
    // port. Only a response is an actual transaction for the evaluator;
    // requests are consumed by the predictor instead.
    if (!t.is_response) return;
    transaction_key = key(t);
    actual_by_key[transaction_key].push_back(t);
    try_compare(transaction_key);
  endfunction

  function void write_expected(hpdcache_item t);
    key_t transaction_key;
    transaction_key = key(t);
    expected_by_key[transaction_key].push_back(t);
    try_compare(transaction_key);
  endfunction

  function void try_compare(key_t transaction_key);
    hpdcache_item actual;
    hpdcache_item expected;
    if (!actual_by_key.exists(transaction_key) ||
        !expected_by_key.exists(transaction_key)) return;
    while (actual_by_key[transaction_key].size() != 0 &&
           expected_by_key[transaction_key].size() != 0) begin
      actual = actual_by_key[transaction_key].pop_front();
      expected = expected_by_key[transaction_key].pop_front();
      checked_responses++;
      if (actual.error)
        `uvm_error(get_type_name(), $sformatf("DUT returned error for tid %0d", actual.tid))
      else if (expected.op == HPDCACHE_REQ_LOAD) begin
        for (int i = 0; i < $bits(expected.data_valid[0]); i++) begin
          if (expected.data_valid[0][i] &&
              actual.data[0][i*8 +: 8] !== expected.data[0][i*8 +: 8])
            `uvm_error(get_type_name(), $sformatf("load mismatch addr=0x%0h byte=%0d expected=0x%02h actual=0x%02h",
                                                  expected.addr, i,
                                                  expected.data[0][i*8 +: 8],
                                                  actual.data[0][i*8 +: 8]))
        end
      end
      else
        `uvm_info(get_type_name(), $sformatf("response matched tid=%0d", actual.tid), UVM_LOW)
    end
    if (actual_by_key[transaction_key].size() == 0)
      actual_by_key.delete(transaction_key);
    if (expected_by_key[transaction_key].size() == 0)
      expected_by_key.delete(transaction_key);
  endfunction

  virtual function void check_phase(uvm_phase phase);
    key_t transaction_key;
    hpdcache_item item;
    super.check_phase(phase);

    foreach (actual_by_key[transaction_key]) begin
      for (int i = 0; i < actual_by_key[transaction_key].size(); i++) begin
        item = actual_by_key[transaction_key][i];
        `uvm_error(get_type_name(), $sformatf(
          "unmatched actual transaction key=0x%0h index=%0d (sid=%0d tid=%0d)",
          transaction_key, i, item.sid, item.tid))
        `uvm_info(get_type_name(),
                  $sformatf("unmatched actual item:\n%s", item.sprint()),
                  UVM_MEDIUM)
      end
    end

    foreach (expected_by_key[transaction_key]) begin
      for (int i = 0; i < expected_by_key[transaction_key].size(); i++) begin
        item = expected_by_key[transaction_key][i];
        `uvm_error(get_type_name(), $sformatf(
          "unmatched expected transaction key=0x%0h index=%0d (sid=%0d tid=%0d)",
          transaction_key, i, item.sid, item.tid))
        `uvm_info(get_type_name(),
                  $sformatf("unmatched expected item:\n%s", item.sprint()),
                  UVM_MEDIUM)
      end
    end
  endfunction

endclass
