`uvm_analysis_imp_decl(_memory_response)
`uvm_analysis_imp_decl(_request)
`uvm_analysis_imp_decl(_cmi_atomic)
class hpdcache_predictor extends uvm_component;
  `uvm_component_utils(hpdcache_predictor)
  uvm_analysis_imp_request #(hpdcache_cri_req_item, hpdcache_predictor) request_imp;
  uvm_analysis_imp_memory_response #(
    memory_txn#(MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH), hpdcache_predictor
  ) memory_response_imp;
  uvm_analysis_imp_cmi_atomic #(
    hpdcache_cmi_atomic_item, hpdcache_predictor
  ) cmi_atomic_imp;
  uvm_analysis_port #(hpdcache_cri_item) expected_port;
  hpdcache_pma_config pma_cfg;
  hpdcache_reference_model reference_model;
  localparam int unsigned REQ_BYTES = REQ_WORDS * (WORD_WIDTH / 8);
  localparam int unsigned SID_W = $bits(hpdcache_req_sid_t);
  localparam int unsigned TID_W = $bits(hpdcache_req_tid_t);
  typedef bit [SID_W+TID_W-1:0] key_t;

  typedef struct {
    hpdcache_cri_item expected;
    bit                ready;
  } pending_expected_t;
  typedef struct {
    key_t              transaction_key;
    hpdcache_cri_item expected;
    bit                waits_for_old_value;
  } pending_atomic_expected_t;

  pending_expected_t pending_expected_q[key_t][$];
  pending_atomic_expected_t pending_atomic_expected_q[$];
  protected int unsigned received_requests;
  protected int unsigned generated_predictions;
  protected int unsigned generated_abort_predictions;
  protected int unsigned no_response_requests;
  protected int unsigned applied_atomic_transactions;
  protected int unsigned completed_atomic_predictions;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    request_imp = new("request_imp", this);
    memory_response_imp = new("memory_response_imp", this);
    cmi_atomic_imp = new("cmi_atomic_imp", this);
    expected_port = new("expected_port", this);
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

  function automatic bit returns_atomic_old_value(hpdcache_req_op_t op);
    return is_amo(op) && op != HPDCACHE_REQ_AMO_SC;
  endfunction

  function automatic mem_atomic_t expected_atomic(hpdcache_req_op_t op);
    case (op)
      HPDCACHE_REQ_AMO_LR:   return MEM_ATOMIC_LDEX;
      HPDCACHE_REQ_AMO_SWAP: return MEM_ATOMIC_SWAP;
      HPDCACHE_REQ_AMO_ADD:  return MEM_ATOMIC_ADD;
      HPDCACHE_REQ_AMO_AND:  return MEM_ATOMIC_CLR;
      HPDCACHE_REQ_AMO_OR:   return MEM_ATOMIC_SET;
      HPDCACHE_REQ_AMO_XOR:  return MEM_ATOMIC_EOR;
      HPDCACHE_REQ_AMO_MAX:  return MEM_ATOMIC_SMAX;
      HPDCACHE_REQ_AMO_MAXU: return MEM_ATOMIC_UMAX;
      HPDCACHE_REQ_AMO_MIN:  return MEM_ATOMIC_SMIN;
      HPDCACHE_REQ_AMO_MINU: return MEM_ATOMIC_UMIN;
      default:               return MEM_ATOMIC_ADD;
    endcase
  endfunction

  function void predict(hpdcache_cri_req_item t);
    key_t transaction_key;
    hpdcache_cri_item exp;
    pending_expected_t pending_expected;
    pending_atomic_expected_t pending_atomic_expected;
    bit cacheable;
    bit sc_expect_cmi;

    transaction_key = key(t);
    cacheable = !pma_cfg.is_uncacheable(t.addr);
    sc_expect_cmi = 1'b0;

    if (!t.abort) begin
      if (t.op == HPDCACHE_REQ_AMO_SC)
        sc_expect_cmi = reference_model.expect_sc_cmi(t);
      else
        reference_model.apply_request(t);
    end

    // CMO requests do not change golden byte values. Invalidate operations
    // only discard cached-byte knowledge so a later refill can be checked.
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
    exp.sc_expect_cmi_valid = !t.abort && t.op == HPDCACHE_REQ_AMO_SC;
    exp.sc_expect_cmi = sc_expect_cmi;

    if (!t.abort && cacheable && t.op == HPDCACHE_REQ_LOAD)
      get_expected_from_reference(exp);
    if (!t.abort && returns_atomic_old_value(t.op)) begin
      if (cacheable)
        get_expected_from_reference(exp);
      pending_atomic_expected.transaction_key = transaction_key;
      pending_atomic_expected.expected = exp;
      pending_atomic_expected.waits_for_old_value =
        cacheable && !requested_data_is_known(exp);
      pending_atomic_expected_q.push_back(pending_atomic_expected);
    end

    pending_expected.expected = exp;
    pending_expected.ready = t.abort ||
                             !cacheable ||
                             (t.op != HPDCACHE_REQ_LOAD &&
                              !returns_atomic_old_value(t.op)) ||
                             requested_data_is_known(exp);
    if (t.abort)
      generated_abort_predictions++;
    pending_expected_q[transaction_key].push_back(pending_expected);
    issue_expected(transaction_key);
  endfunction

  function void get_expected_from_reference(hpdcache_cri_item exp);
    longint unsigned byte_addr;
    logic [7:0] golden_byte;
    int unsigned byte_offset;
    int unsigned byte_count;

    byte_offset = longint'(exp.addr) % REQ_BYTES;
    byte_count = 1 << exp.size;
    for (int unsigned i = 0; i < REQ_BYTES; i++) begin
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

  function void get_expected_from_response(
    hpdcache_cri_item exp,
    logic [MEM_ADDR_WIDTH-1:0] response_addr,
    logic [MEM_DATA_WIDTH-1:0] response_data
  );
    longint unsigned byte_addr;
    longint unsigned response_word;
    int unsigned byte_offset;
    int unsigned byte_count;
    int unsigned memory_byte;

    byte_offset = longint'(exp.addr) % REQ_BYTES;
    byte_count = 1 << exp.size;
    response_word = longint'(response_addr) / (MEM_DATA_WIDTH / 8);
    for (int unsigned i = 0; i < REQ_BYTES; i++) begin
      if (i < byte_offset || i >= byte_offset + byte_count ||
          exp.data_valid[0][i])
        continue;
      byte_addr = (longint'(exp.addr) / REQ_BYTES) * REQ_BYTES + i;
      if (byte_addr / (MEM_DATA_WIDTH / 8) != response_word)
        continue;
      memory_byte = byte_addr % (MEM_DATA_WIDTH / 8);
      exp.data[0][i*8 +: 8] = response_data[memory_byte*8 +: 8];
      exp.data_valid[0][i] = 1'b1;
    end
  endfunction

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

  function bit requested_data_is_known(hpdcache_cri_item exp);
    int unsigned byte_offset;
    int unsigned byte_count;

    byte_offset = longint'(exp.addr) % REQ_BYTES;
    byte_count = 1 << exp.size;
    for (int unsigned i = 0; i < $bits(exp.data_valid[0]); i++) begin
      if (i >= byte_offset && i < byte_offset + byte_count &&
          !exp.data_valid[0][i])
        return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function void complete_atomic_expected(hpdcache_cmi_atomic_item t);
    pending_atomic_expected_t pending_atomic_expected;
    hpdcache_cri_item expected;
    bit identity_matches;
    bit found;

    if (pending_atomic_expected_q.size() == 0) begin
      `uvm_error("HPDCACHE_CHK_PREDICTOR", $sformatf(
        "atomic response has no pending CRI request addr=0x%0h atop=%s",
        t.addr, t.atop.name()))
      return;
    end

    pending_atomic_expected = pending_atomic_expected_q.pop_front();
    expected = pending_atomic_expected.expected;
    identity_matches = hpdcache_req_addr_t'(t.addr) === expected.addr &&
                       t.atop == expected_atomic(expected.op);
    if (!identity_matches)
      `uvm_error("HPDCACHE_CHK_PREDICTOR", $sformatf(
        "atomic response mismatch expected_addr=0x%0h actual_addr=0x%0h expected_op=%s actual_atop=%s",
        expected.addr, t.addr, expected.op.name(), t.atop.name()))

    if (pending_atomic_expected.waits_for_old_value) begin
      if (identity_matches && !t.err && t.read_response_valid)
        get_expected_from_response(expected, t.addr, t.response_data);

      found = 1'b0;
      if (pending_expected_q.exists(pending_atomic_expected.transaction_key)) begin
        for (int unsigned i = 0;
             i < pending_expected_q[pending_atomic_expected.transaction_key].size();
             i++) begin
          if (pending_expected_q[pending_atomic_expected.transaction_key][i].expected ==
              expected) begin
            pending_expected_q[pending_atomic_expected.transaction_key][i].ready =
              t.err || requested_data_is_known(expected);
            if (!pending_expected_q[pending_atomic_expected.transaction_key][i].ready) begin
              `uvm_error("HPDCACHE_CHK_PREDICTOR", $sformatf(
                "atomic old value remains unknown addr=0x%0h op=%s",
                expected.addr, expected.op.name()))
              pending_expected_q[pending_atomic_expected.transaction_key][i].ready =
                1'b1;
            end
            found = 1'b1;
            break;
          end
        end
      end
      if (!found)
        `uvm_error("HPDCACHE_CHK_PREDICTOR", $sformatf(
          "pending atomic expected was not found SID=%0d TID=%0d",
          expected.sid, expected.tid))
      else
        issue_expected(pending_atomic_expected.transaction_key);
    end
    completed_atomic_predictions++;
  endfunction

  function automatic bit is_idle();
    return pending_expected_q.num() == 0 &&
           pending_atomic_expected_q.size() == 0;
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
    pending_atomic_expected_q.delete();
  endtask

  function void write_cmi_atomic(hpdcache_cmi_atomic_item t);
    applied_atomic_transactions++;
    if (t.atop != MEM_ATOMIC_STEX)
      complete_atomic_expected(t);
    reference_model.apply_atomic_transaction(t);
  endfunction

  function void write_memory_response(
    memory_txn#(MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH) t
  );
    key_t transaction_key;
    key_t retry_keys[$];

    // ap_mem_rd_rsp only publishes read responses.  HPDcache reserves the
    // all-ones ID for uncached and atomic traffic, so exclude those responses
    // from the cache-refill path.
    if (t.err || t.id == {MEM_ID_WIDTH{1'b1}})
      return;
    if (!reference_model.apply_memory_response(t))
      return;
    foreach (pending_expected_q[transaction_key])
      retry_keys.push_back(transaction_key);
    foreach (retry_keys[i]) begin
      for (int j = 0; j < pending_expected_q[retry_keys[i]].size(); j++) begin
        if (pending_expected_q[retry_keys[i]][j].ready)
          continue;
        if (pending_expected_q[retry_keys[i]][j].expected.op ==
            HPDCACHE_REQ_LOAD) begin
          get_expected_from_response(
            pending_expected_q[retry_keys[i]][j].expected, t.addr, t.data
          );
          pending_expected_q[retry_keys[i]][j].ready = requested_data_is_known(
            pending_expected_q[retry_keys[i]][j].expected
          );
        end
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
    foreach (pending_atomic_expected_q[i]) begin
      item = pending_atomic_expected_q[i].expected;
      `uvm_error("HPDCACHE_CHK_PREDICTOR", $sformatf(
        "unresolved atomic expected index=%0d (sid=%0d tid=%0d op=%s addr=0x%0h)",
        i, item.sid, item.tid, item.op.name(), item.addr))
    end
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("HPDCACHE_RPT_CHECK_PREDICTOR", $sformatf(
      "requests=%0d predictions=%0d abort_predictions=%0d no_rsp=%0d pending=%0d atomic_updates=%0d atomic_predictions=%0d pending_atomics=%0d",
      received_requests, generated_predictions, generated_abort_predictions,
      no_response_requests, num_pending(), applied_atomic_transactions,
      completed_atomic_predictions, pending_atomic_expected_q.size()), UVM_NONE)
  endfunction
endclass
