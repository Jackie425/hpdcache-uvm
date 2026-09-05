`uvm_analysis_imp_decl(_memory_response)
`uvm_analysis_imp_decl(_request)
class hpdcache_predictor extends uvm_component;
  `uvm_component_utils(hpdcache_predictor)
  uvm_analysis_imp_request #(hpdcache_cri_req_item, hpdcache_predictor) request_imp;
  uvm_analysis_port #(hpdcache_cri_item) expected_port;
  uvm_analysis_imp_memory_response #(
    memory_txn#(MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH), hpdcache_predictor
  ) memory_response_imp;
  hpdcache_pma_config pma_cfg;
  hpdcache_reference_model reference_model;
  localparam int unsigned MEM_BYTES = MEM_DATA_WIDTH / 8;
  localparam int unsigned REQ_BYTES = REQ_WORDS * (WORD_WIDTH / 8);
  localparam int unsigned SID_W = $bits(hpdcache_req_sid_t);
  localparam int unsigned TID_W = $bits(hpdcache_req_tid_t);
  typedef bit [SID_W+TID_W-1:0] key_t;
  typedef struct {
    hpdcache_cri_item expected;
    bit           ready;
  } pending_expected_t;

  // Each protocol key owns an ordered queue. An expected response may become
  // ready before an older response with the same key, but it cannot be sent to
  // the evaluator until every entry ahead of it has been sent.
  pending_expected_t pending_expected_q[key_t][$];
  protected int unsigned received_requests;
  protected int unsigned generated_predictions;
  protected int unsigned generated_abort_predictions;
  protected int unsigned no_response_requests;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    request_imp = new("request_imp", this);
    expected_port = new("expected_port", this);
    memory_response_imp = new("memory_response_imp", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(hpdcache_pma_config)::get(
          this, "", "pma_cfg", pma_cfg) || pma_cfg == null)
      `uvm_fatal(get_type_name(), "hpdcache_pma_config was not configured")
    reference_model = hpdcache_reference_model::type_id::create(
      "reference_model", this
    );
  endfunction

  virtual function void write_request(hpdcache_cri_req_item t);
    received_requests++;
    predict(t);
  endfunction

  function automatic key_t key(hpdcache_cri_req_item t);
    return {t.sid, t.tid};
  endfunction

  function void predict(hpdcache_cri_req_item t);
    key_t transaction_key;
    hpdcache_cri_item exp;
    pending_expected_t pending_expected;
    transaction_key = key(t);

    if (!t.abort && t.op == HPDCACHE_REQ_STORE)
      reference_model.apply_request(t);
    if (!t.need_rsp) begin
      no_response_requests++;
      return;
    end

    if (!$cast(exp, t.clone()))
      `uvm_fatal(get_type_name(), "failed to clone request for prediction")
    exp.set_name("expected_response");
    exp.is_response = 1'b1;
    exp.error = 1'b0;
    exp.aborted = t.abort;
    exp.data_valid = '0;
    if (!t.abort && t.op == HPDCACHE_REQ_LOAD)
      get_expected_from_reference(exp);

    pending_expected.expected = exp;
    pending_expected.ready = t.abort ||
                             (t.op != HPDCACHE_REQ_LOAD) ||
                             load_is_known(exp);
    if (t.abort)
      generated_abort_predictions++;
    pending_expected_q[transaction_key].push_back(pending_expected);
    issue_expected(transaction_key);
  endfunction

  // Fill bytes that have become known without repeating request-side effects.
  function void get_expected_from_reference(hpdcache_cri_item exp);
    longint unsigned byte_addr;
    logic [7:0] golden_byte;
    int unsigned byte_offset;
    int unsigned byte_count;

    byte_offset = longint'(exp.addr) % REQ_BYTES;
    byte_count = 1 << exp.size;
    for (int i = 0; i < REQ_BYTES; i++) begin
      if (i < byte_offset || i >= byte_offset + byte_count ||
          exp.data_valid[0][i])
        continue;
      byte_addr = (longint'(exp.addr) / REQ_BYTES) * REQ_BYTES + i;
      if (reference_model.read_byte(byte_addr, golden_byte)) begin
        exp.data[0][i*8 +: 8] = golden_byte;
        exp.data_valid[0][i] = 1'b1;
      end
    end
  endfunction

  // Complete a pending load from the refill itself so later stores already
  // present in the reference model cannot change the load's earlier snapshot.
  function void get_expected_from_memory_response(
    hpdcache_cri_item exp,
    memory_txn#(MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH) t
  );
    longint unsigned byte_addr;
    longint unsigned response_word;
    int unsigned byte_offset;
    int unsigned byte_count;
    int unsigned memory_byte;

    byte_offset = longint'(exp.addr) % REQ_BYTES;
    byte_count = 1 << exp.size;
    response_word = longint'(t.addr) / MEM_BYTES;
    for (int i = 0; i < REQ_BYTES; i++) begin
      if (i < byte_offset || i >= byte_offset + byte_count ||
          exp.data_valid[0][i])
        continue;
      byte_addr = (longint'(exp.addr) / REQ_BYTES) * REQ_BYTES + i;
      if (byte_addr / MEM_BYTES != response_word)
        continue;
      memory_byte = byte_addr % MEM_BYTES;
      exp.data[0][i*8 +: 8] = t.data[memory_byte*8 +: 8];
      exp.data_valid[0][i] = 1'b1;
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
      generated_predictions++;
      expected_port.write(pending_expected.expected);
    end
    if (pending_expected_q.exists(transaction_key) &&
        pending_expected_q[transaction_key].size() == 0)
      pending_expected_q.delete(transaction_key);
  endfunction

  // A load is ready only when every requested byte has been learned.
  function bit load_is_known(hpdcache_cri_item exp);
    int unsigned byte_offset;
    int unsigned byte_count;

    byte_offset = longint'(exp.addr) % REQ_BYTES;
    byte_count = 1 << exp.size;
    for (int i = 0; i < $bits(exp.data_valid[0]); i++) begin
      if (i >= byte_offset && i < byte_offset + byte_count &&
          !exp.data_valid[0][i])
        return 1'b0;
    end
    return 1'b1;
  endfunction

  function automatic bit is_idle();
    return pending_expected_q.num() == 0;
  endfunction

  function automatic int unsigned num_pending();
    key_t transaction_key;
    int unsigned pending = 0;
    foreach (pending_expected_q[transaction_key])
      pending += pending_expected_q[transaction_key].size();
    return pending;
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
        get_expected_from_memory_response(
          pending_expected_q[retry_keys[i]][j].expected,
          t
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
    hpdcache_cri_item item;
    super.check_phase(phase);

    foreach (pending_expected_q[transaction_key]) begin
      for (int i = 0; i < pending_expected_q[transaction_key].size(); i++) begin
        item = pending_expected_q[transaction_key][i].expected;
        `uvm_error("HPDCACHE_CHK_PREDICTOR", $sformatf(
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

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("HPDCACHE_RPT_CHECK_PREDICTOR", $sformatf(
      "requests=%0d predictions=%0d abort_predictions=%0d no_rsp=%0d pending=%0d",
      received_requests, generated_predictions, generated_abort_predictions,
      no_response_requests, num_pending()), UVM_NONE)
  endfunction
endclass
