`uvm_analysis_imp_decl(_memory_response)
`uvm_analysis_imp_decl(_request)
class hpdcache_predictor extends uvm_component;
  `uvm_component_utils(hpdcache_predictor)
  // The monitor stream contains both requests and responses.  The predictor
  // consumes it directly through an analysis implementation and ignores
  // response objects; response buffering belongs to the scoreboard.
  uvm_analysis_imp_request #(hpdcache_item, hpdcache_predictor) request_imp;
  uvm_analysis_port #(hpdcache_item) expected_port;
  uvm_analysis_imp_memory_response #(
    memory_txn#(MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH), hpdcache_predictor
  ) memory_response_imp;
  hpdcache_reference_model reference_model;
  localparam int unsigned REQ_BYTES = REQ_WORDS * (WORD_WIDTH / 8);
  localparam int unsigned SID_W = $bits(hpdcache_req_sid_t);
  localparam int unsigned TID_W = $bits(hpdcache_req_tid_t);
  typedef bit [SID_W+TID_W-1:0] key_t;
  typedef struct {
    hpdcache_item expected;
    bit           ready;
  } pending_expected_t;

  // Each protocol key owns an ordered queue. An expected response may become
  // ready before an older response with the same key, but it cannot be sent to
  // the evaluator until every entry ahead of it has been sent.
  pending_expected_t pending_expected_q[key_t][$];

  function new(string name, uvm_component parent);
    super.new(name, parent);
    request_imp = new("request_imp", this);
    expected_port = new("expected_port", this);
    memory_response_imp = new("memory_response_imp", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    reference_model = hpdcache_reference_model::type_id::create(
      "reference_model", this
    );
  endfunction

  virtual function void write_request(hpdcache_item t);
    if (!t.is_response)
      predict(t);
  endfunction

  function automatic key_t key(hpdcache_item t);
    return {t.sid, t.tid};
  endfunction

  function void predict(hpdcache_item t);
    key_t transaction_key;
    hpdcache_item exp;
    pending_expected_t pending_expected;
    transaction_key = key(t);
    exp = hpdcache_item::type_id::create("expected_response");
    exp.copy(t);
    exp.is_response = 1'b1;
    exp.error = 1'b0;
    exp.data_valid = '0;
    if (t.op == HPDCACHE_REQ_STORE) begin
      reference_model.apply_request(t);
    end else if (t.op == HPDCACHE_REQ_LOAD) begin
      get_expected_from_reference(exp);
    end

    pending_expected.expected = exp;
    pending_expected.ready = (t.op != HPDCACHE_REQ_LOAD) || load_is_known(exp);
    pending_expected_q[transaction_key].push_back(pending_expected);
    issue_expected(transaction_key);
  endfunction

  // Fill bytes that have become known without repeating request-side effects.
  function void get_expected_from_reference(hpdcache_item exp);
    longint unsigned byte_addr;
    logic [7:0] golden_byte;
    for (int i = 0; i < REQ_BYTES; i++) begin
      if (!exp.be[0][i] || exp.data_valid[0][i]) continue;
      byte_addr = longint'(exp.addr) + i;
      if (reference_model.read_byte(byte_addr, golden_byte)) begin
        exp.data[0][i*8 +: 8] = golden_byte;
        exp.data_valid[0][i] = 1'b1;
      end
    end
  endfunction

  // Publish only a contiguous ready prefix so expected responses for a reused
  // key retain request order even when their prediction becomes ready out of
  // order.
  function void issue_expected(key_t transaction_key);
    pending_expected_t pending_expected;
    while (pending_expected_q.exists(transaction_key) &&
           pending_expected_q[transaction_key].size() != 0 &&
           pending_expected_q[transaction_key][0].ready) begin
      pending_expected = pending_expected_q[transaction_key].pop_front();
      expected_port.write(pending_expected.expected);
    end
    if (pending_expected_q.exists(transaction_key) &&
        pending_expected_q[transaction_key].size() == 0)
      pending_expected_q.delete(transaction_key);
  endfunction

  // A load is ready only when every requested byte has been learned.
  function bit load_is_known(hpdcache_item exp);
    for (int i = 0; i < $bits(exp.data_valid[0]); i++) begin
      if (exp.be[0][i] && !exp.data_valid[0][i])
        return 1'b0;
    end
    return 1'b1;
  endfunction

  function automatic bit is_idle();
    return pending_expected_q.num() == 0;
  endfunction

  virtual task reset_phase(uvm_phase phase);
    super.reset_phase(phase);
    reference_model.reset();
    pending_expected_q.delete();
  endtask

  function void write_memory_response(
    memory_txn#(MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH) t
  );
    key_t transaction_key;
    key_t retry_keys[$];
    if (!reference_model.apply_memory_response(t)) return;
    // A response can complete any queued load, including an entry behind a
    // blocked head, so refresh every not-ready expected before issuing keys.
    foreach (pending_expected_q[transaction_key])
      retry_keys.push_back(transaction_key);
    foreach (retry_keys[i]) begin
      for (int j = 0; j < pending_expected_q[retry_keys[i]].size(); j++) begin
        if (pending_expected_q[retry_keys[i]][j].ready) continue;
        get_expected_from_reference(
          pending_expected_q[retry_keys[i]][j].expected
        );
        pending_expected_q[retry_keys[i]][j].ready = load_is_known(
          pending_expected_q[retry_keys[i]][j].expected
        );
      end
      issue_expected(retry_keys[i]);
    end
  endfunction

  virtual function void check_phase(uvm_phase phase);
    key_t transaction_key;
    hpdcache_item item;
    super.check_phase(phase);

    foreach (pending_expected_q[transaction_key]) begin
      for (int i = 0; i < pending_expected_q[transaction_key].size(); i++) begin
        item = pending_expected_q[transaction_key][i].expected;
        `uvm_error(get_type_name(), $sformatf(
          "unresolved pending expected key=0x%0h index=%0d ready=%0b (sid=%0d tid=%0d)",
          transaction_key, i,
          pending_expected_q[transaction_key][i].ready,
          item.sid, item.tid))
        `uvm_info(get_type_name(),
                  $sformatf("pending expected:\n%s", item.sprint()),
                  UVM_MEDIUM)
      end
    end
  endfunction
endclass
