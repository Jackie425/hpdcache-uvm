class hpdcache_random_test extends hpdcache_base_test;
  `uvm_component_utils(hpdcache_random_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_sequence();
    localparam int unsigned ITEM_NUM = 1000;
    hpdcache_random_vseq random_vseq;

    random_vseq = hpdcache_random_vseq::type_id::create("random_vseq");
    init_vseq(random_vseq);
    random_vseq.item_num = ITEM_NUM;
    random_vseq.start(null);
  endtask
endclass
