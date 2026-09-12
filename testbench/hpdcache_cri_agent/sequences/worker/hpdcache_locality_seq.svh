class hpdcache_locality_seq extends uvm_sequence #(hpdcache_cri_item);
  `uvm_object_utils(hpdcache_locality_seq)
  `uvm_declare_p_sequencer(hpdcache_cri_sequencer)

  int unsigned item_num;
  int unsigned locality_size;

  function new(string name = "hpdcache_locality_seq");
    super.new(name);
    locality_size = 4096;
  endfunction

  task body();
    localparam int unsigned CACHELINE_BYTES =
      1 << HPDCACHE_CFG.clOffsetWidth;
    hpdcache_pma_config::pma_region_t pma_region;
    hpdcache_addr_range_t addr_range;

    if (p_sequencer == null || p_sequencer.cfg == null ||
        p_sequencer.cfg.pma_cfg == null)
      `uvm_fatal(get_type_name(), "locality worker has no PMA configuration")

    pma_region = p_sequencer.cfg.pma_cfg.random_pma_region(1'b1);
    if (locality_size == 0 ||
        locality_size % CACHELINE_BYTES != 0 ||
        locality_size > pma_region.last - pma_region.base + 1)
      `uvm_fatal(get_type_name(),
        "locality_size must fit whole cache lines in the PMA region")

    if (!std::randomize(addr_range.base) with {
      addr_range.base inside {
        [pma_region.base:pma_region.last-locality_size+1]
      };
      (addr_range.base % CACHELINE_BYTES) == 0;
    })
      `uvm_fatal(get_type_name(), "failed to choose the locality range")

    addr_range.valid = 1'b1;
    addr_range.last = addr_range.base + locality_size - 1;

    for (int unsigned i = 0; i < item_num; i++) begin
      automatic int unsigned sequence_index = i;
      fork
        begin
          hpdcache_ldst_seq_api api_seq;

          api_seq = hpdcache_ldst_seq_api::type_id::create(
            $sformatf("locality_ldst_api_%0d", sequence_index)
          );
          api_seq.address_range = addr_range;
          api_seq.start(p_sequencer, this);
        end
      join_none
    end
    wait fork;
  endtask
endclass
