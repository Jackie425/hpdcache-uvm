class hpdcache_locality_vseq extends hpdcache_base_vseq;
  `uvm_object_utils(hpdcache_locality_vseq)

  int unsigned item_num;
  int unsigned locality_size;

  function new(string name = "hpdcache_locality_vseq");
    super.new(name);
    locality_size = 4096;
  endfunction

  virtual task body();
    if (item_num == 0)
      `uvm_fatal(get_type_name(), "item_num was not configured")

    for (int unsigned i = 0; i < cri_sequencers.size(); i++) begin
      automatic int unsigned worker_index = i;
      fork
        begin
          hpdcache_locality_seq worker;
          worker = hpdcache_locality_seq::type_id::create(
            $sformatf("locality_worker_%0d", worker_index)
          );
          worker.item_num = item_num;
          worker.locality_size = locality_size;
          worker.start(cri_sequencers[worker_index], this);
        end
      join_none
    end
    wait fork;
    `uvm_info("HPDCACHE_RPT_STIMULUS", $sformatf(
      "vseq=%s worker=hpdcache_locality_seq api_sequence=hpdcache_ldst_seq_api workers=%0d items_per_worker=%0d locality_size=%0d planned=%0d",
      get_type_name(), cri_sequencers.size(), item_num, locality_size,
      cri_sequencers.size() * item_num), UVM_NONE)
  endtask
endclass
