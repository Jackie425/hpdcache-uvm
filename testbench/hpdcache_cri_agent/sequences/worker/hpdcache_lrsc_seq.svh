class hpdcache_lrsc_seq extends uvm_sequence #(hpdcache_cri_item);
  `uvm_object_utils(hpdcache_lrsc_seq)
  `uvm_declare_p_sequencer(hpdcache_cri_sequencer)

  // The atomic worker uses this limit to keep its requested item count exact.
  rand int unsigned inter_ops;
  int unsigned max_inter_ops;
  int unsigned items_sent;

  constraint inter_ops_c {
    inter_ops inside {[0:3]};
    inter_ops <= max_inter_ops;
  }

  function new(string name = "hpdcache_lrsc_seq");
    super.new(name);
    max_inter_ops = 3;
    items_sent = 0;
  endfunction

  protected task check_response(
    hpdcache_cri_item response,
    hpdcache_req_tid_t expected_tid
  );
    if (response == null)
      `uvm_error("HPDCACHE_CHK_SEQUENCE", "received a null driver response")
    else begin
      if (response.sid != p_sequencer.cfg.requester_id)
        `uvm_error("HPDCACHE_CHK_SEQUENCE", $sformatf(
          "response SID %0d does not match requester %0d",
          response.sid, p_sequencer.cfg.requester_id))
      if (response.tid != expected_tid)
        `uvm_error("HPDCACHE_CHK_SEQUENCE", $sformatf(
          "response TID %0d does not match allocated TID %0d",
          int'(response.tid), int'(expected_tid)))
    end
  endtask

  task body();
    hpdcache_amo_seq_api lr_seq;
    hpdcache_cri_item sc_req;
    hpdcache_cri_item sc_rsp;
    hpdcache_random_seq_api inter_seq;
    hpdcache_req_tid_t sc_tid;

    items_sent = 0;

    if (p_sequencer == null)
      `uvm_fatal(get_type_name(), "LRSC worker has no CRI sequencer")
    if (p_sequencer.cfg == null)
      `uvm_fatal(get_type_name(), "LRSC worker has no agent configuration")

    lr_seq = hpdcache_amo_seq_api::type_id::create("lr_api");
    if (!lr_seq.randomize() with {
      amo_op == HPDCACHE_REQ_AMO_LR;
    })
      `uvm_fatal(get_type_name(), "failed to constrain the LR API")
    lr_seq.start(p_sequencer, this);

    // Keep the requests ordered so every instruction is issued after LR has
    // completed and before the matching SC is generated.  The random API also
    // exercises ordinary loads/stores, AMOs, and CMOs between the pair.
    for (int unsigned i = 0; i < inter_ops; i++) begin
      inter_seq = hpdcache_random_seq_api::type_id::create(
        $sformatf("lrsc_inter_api_%0d", i)
      );
      inter_seq.start(p_sequencer, this);
    end

    p_sequencer.acquire_tid(sc_tid);
    sc_req = hpdcache_cri_item::type_id::create("sc_req");
    sc_req.sid = p_sequencer.cfg.requester_id;
    sc_req.tid = sc_tid;
    start_item(sc_req);
    if (!sc_req.randomize() with {
      op == HPDCACHE_REQ_AMO_SC;
      abort == 1'b0;
    })
      `uvm_fatal(get_type_name(), "failed to randomize the SC item")
    sc_req.addr = lr_seq.req.addr;
    sc_req.size = lr_seq.req.size;
    sc_req.be = lr_seq.req.be;
    sc_req.pma = lr_seq.req.pma;
    finish_item(sc_req);
    get_response(sc_rsp);
    check_response(sc_rsp, sc_tid);
    p_sequencer.release_tid(sc_tid);
    items_sent = 2 + inter_ops;
  endtask
endclass
