typedef enum bit {
  HPDCACHE_CACHEABLE   = 1'b0,
  HPDCACHE_UNCACHEABLE = 1'b1
} hpdcache_cacheability_e;

class hpdcache_pma_config extends uvm_object;
  `uvm_object_utils(hpdcache_pma_config)

  typedef struct {
    hpdcache_req_addr_t     base_addr;
    hpdcache_req_addr_t     last_addr;
    hpdcache_cacheability_e cacheability;
  } region_t;

  protected region_t regions[$];

  function new(string name = "hpdcache_pma_config");
    super.new(name);
  endfunction

  function void add_region(
    hpdcache_req_addr_t     base_addr,
    hpdcache_req_addr_t     last_addr,
    hpdcache_cacheability_e cacheability
  );
    region_t region;

    region.base_addr    = base_addr;
    region.last_addr    = last_addr;
    region.cacheability = cacheability;
    regions.push_back(region);
  endfunction

  function void clear_regions();
    regions.delete();
  endfunction

  function automatic int unsigned num_regions();
    return regions.size();
  endfunction

  function automatic hpdcache_req_addr_t region_base(int unsigned index);
    return regions[index].base_addr;
  endfunction

  function automatic hpdcache_req_addr_t region_last(int unsigned index);
    return regions[index].last_addr;
  endfunction

  function automatic bit region_is_uncacheable(int unsigned index);
    return regions[index].cacheability == HPDCACHE_UNCACHEABLE;
  endfunction

  function automatic int find_region(hpdcache_req_addr_t addr);
    foreach (regions[i]) begin
      if (addr inside {[regions[i].base_addr:regions[i].last_addr]})
        return i;
    end
    return -1;
  endfunction

  function automatic bit is_mapped(hpdcache_req_addr_t addr);
    return find_region(addr) >= 0;
  endfunction

  function automatic bit is_uncacheable(hpdcache_req_addr_t addr);
    int index;

    index = find_region(addr);
    return index >= 0 &&
           regions[index].cacheability == HPDCACHE_UNCACHEABLE;
  endfunction

  function void validate();
    localparam int unsigned CACHELINE_BYTES = 1 << HPDCACHE_CFG.clOffsetWidth;

    if (regions.size() == 0)
      `uvm_fatal(get_type_name(), "at least one PMA region is required")

    foreach (regions[i]) begin
      if (regions[i].base_addr > regions[i].last_addr)
        `uvm_fatal(get_type_name(), $sformatf(
          "PMA region %0d has an inverted range [0x%0h:0x%0h]",
          i, regions[i].base_addr, regions[i].last_addr))
      if ((regions[i].base_addr % CACHELINE_BYTES) != 0 ||
          (regions[i].last_addr % CACHELINE_BYTES) != CACHELINE_BYTES - 1)
        `uvm_fatal(get_type_name(), $sformatf(
          "PMA region %0d must be cacheline aligned", i))
      for (int j = 0; j < i; j++) begin
        if (regions[i].base_addr <= regions[j].last_addr &&
            regions[j].base_addr <= regions[i].last_addr)
          `uvm_fatal(get_type_name(), $sformatf(
            "PMA regions %0d and %0d overlap", j, i))
      end
    end
  endfunction
endclass
