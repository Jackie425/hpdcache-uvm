class hpdcache_atomic_test extends hpdcache_base_test;
  `uvm_component_utils(hpdcache_atomic_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_sequence();
    localparam int unsigned ITEM_NUM = 1000;
    hpdcache_atomic_vseq atomic_vseq;

    atomic_vseq = hpdcache_atomic_vseq::type_id::create("atomic_vseq");
    init_vseq(atomic_vseq);
    atomic_vseq.item_num = ITEM_NUM;
    atomic_vseq.start(null);
  endtask
endclass
