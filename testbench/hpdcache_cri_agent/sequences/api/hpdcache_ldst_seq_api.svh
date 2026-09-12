class hpdcache_ldst_seq_api extends hpdcache_base_seq;
  `uvm_object_utils(hpdcache_ldst_seq_api)

  function new(string name = "hpdcache_ldst_seq_api");
    super.new(name);
  endfunction

  task body();
    start_item(req);
    if (!req.randomize() with {
      op inside {HPDCACHE_REQ_LOAD, HPDCACHE_REQ_STORE};
      abort == 1'b0;
    })
      `uvm_fatal(get_type_name(), "failed to randomize the load/store item")
    finish_item(req);
  endtask
endclass
