class hpdcache_random_seq_api extends hpdcache_base_seq;
  `uvm_object_utils(hpdcache_random_seq_api)

  function new(string name = "hpdcache_random_seq_api");
    super.new(name);
  endfunction

  task body();
    start_item(req);
    if (!req.randomize())
      `uvm_fatal(get_type_name(), "failed to randomize the item")
    finish_item(req);
  endtask
endclass
