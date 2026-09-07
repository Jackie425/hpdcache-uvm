class hpdcache_amo_seq_api extends hpdcache_base_seq;
  `uvm_object_utils(hpdcache_amo_seq_api)

  // The API owns the AMO operation constraint.  Directed workers may override
  // the soft default without duplicating the ordinary AMO opcode list.
  rand hpdcache_req_op_t amo_op;

  constraint legal_amo_operation_c {
    amo_op inside {
      HPDCACHE_REQ_AMO_LR,
      HPDCACHE_REQ_AMO_SC,
      HPDCACHE_REQ_AMO_SWAP,
      HPDCACHE_REQ_AMO_ADD,
      HPDCACHE_REQ_AMO_AND,
      HPDCACHE_REQ_AMO_OR,
      HPDCACHE_REQ_AMO_XOR,
      HPDCACHE_REQ_AMO_MAX,
      HPDCACHE_REQ_AMO_MAXU,
      HPDCACHE_REQ_AMO_MIN,
      HPDCACHE_REQ_AMO_MINU
    };
  }

  constraint default_amo_operation_c {
    soft amo_op dist {
      HPDCACHE_REQ_AMO_SWAP := 1,
      HPDCACHE_REQ_AMO_ADD  := 1,
      HPDCACHE_REQ_AMO_AND  := 1,
      HPDCACHE_REQ_AMO_OR   := 1,
      HPDCACHE_REQ_AMO_XOR  := 1,
      HPDCACHE_REQ_AMO_MAX  := 1,
      HPDCACHE_REQ_AMO_MAXU := 1,
      HPDCACHE_REQ_AMO_MIN  := 1,
      HPDCACHE_REQ_AMO_MINU := 1
    };
  }

  function new(string name = "hpdcache_amo_seq_api");
    super.new(name);
    amo_op = HPDCACHE_REQ_AMO_ADD;
  endfunction

  task body();
    start_item(req);
    if (!req.randomize() with {
      op == amo_op;
      abort == 1'b0;
    })
      `uvm_fatal(get_type_name(), "failed to randomize the AMO item")
    finish_item(req);
  endtask
endclass
