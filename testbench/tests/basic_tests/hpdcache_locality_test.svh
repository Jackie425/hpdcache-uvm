class hpdcache_locality_test extends hpdcache_base_test;
  `uvm_component_utils(hpdcache_locality_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_sequence();
    localparam int unsigned ITEM_NUM = 1000;
    localparam int unsigned LOCALITY_SIZE = 4096;
    hpdcache_locality_vseq locality_vseq;

    locality_vseq = hpdcache_locality_vseq::type_id::create("locality_vseq");
    init_vseq(locality_vseq);
    locality_vseq.item_num = ITEM_NUM;
    locality_vseq.locality_size = LOCALITY_SIZE;
    locality_vseq.start(null);
  endtask
endclass
