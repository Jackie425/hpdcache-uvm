typedef enum bit {
  HPDCACHE_CACHEABLE   = 1'b0,
  HPDCACHE_UNCACHEABLE = 1'b1
} hpdcache_cacheability_e;

class hpdcache_pma_config extends uvm_object;
  `uvm_object_utils(hpdcache_pma_config)

  typedef struct {
    hpdcache_req_addr_t     base;
    hpdcache_req_addr_t     last;
    hpdcache_cacheability_e cacheability;
  } pma_region_t;

  protected pma_region_t pma_regions[$];

  function new(string name = "hpdcache_pma_config");
    super.new(name);
  endfunction

  function void add_pma_region(
    hpdcache_req_addr_t     base_addr,
    hpdcache_req_addr_t     last_addr,
    hpdcache_cacheability_e cacheability
  );
    pma_region_t pma_region;

    pma_region.base = base_addr;
    pma_region.last = last_addr;
    pma_region.cacheability = cacheability;
    pma_regions.push_back(pma_region);
  endfunction

  function void clear_pma_regions();
    pma_regions.delete();
  endfunction

  function void generate_random_pma_regions();
    localparam int unsigned PA_WIDTH = HPDCACHE_CFG.u.paWidth;
    localparam int unsigned MIN_PMA_REGION_COUNT = 2;
    localparam int unsigned MAX_PMA_REGION_COUNT = 5;
    // Model a small SoC address map with a few large, naturally aligned
    // windows. Sizes range from 256 MiB to 4 TiB.
    localparam int unsigned MIN_REGION_LOG2 = 28;
    localparam int unsigned MAX_REGION_LOG2 = 42;
    localparam longint unsigned PA_SPACE_LAST = (64'd1 << PA_WIDTH) - 1;

    int unsigned pma_region_count;
    int unsigned pma_region_size_log2;
    longint unsigned pma_region_size;
    longint unsigned pma_region_base;
    hpdcache_cacheability_e pma_region_cacheability;
    bit overlap;
    int unsigned attempts;
    bit have_cacheable;
    bit have_uncacheable;

    clear_pma_regions();
    have_cacheable = 1'b0;
    have_uncacheable = 1'b0;

    if (PA_WIDTH <= MAX_REGION_LOG2 || PA_WIDTH >= 63)
      `uvm_fatal(get_type_name(), "unsupported physical address width for PMA generation")
    if (!std::randomize(pma_region_count) with {
      pma_region_count inside {
        [MIN_PMA_REGION_COUNT:MAX_PMA_REGION_COUNT]
      };
    })
      `uvm_fatal(get_type_name(), "failed to randomize the PMA region count")

    for (int unsigned i = 0; i < pma_region_count; i++) begin
      overlap = 1'b1;
      attempts = 0;
      while (overlap && attempts++ < 1000) begin
        if (!std::randomize(pma_region_size_log2) with {
          pma_region_size_log2 inside {[MIN_REGION_LOG2:MAX_REGION_LOG2]};
        })
          `uvm_fatal(get_type_name(), "failed to randomize the PMA segment size")
        pma_region_size = 64'd1 << pma_region_size_log2;
        if (!std::randomize(pma_region_base) with {
          pma_region_base inside {
            [0:PA_SPACE_LAST - pma_region_size + 1]
          };
        })
          `uvm_fatal(get_type_name(), "failed to randomize the PMA segment base")
        pma_region_base =
          (pma_region_base / pma_region_size) * pma_region_size;

        overlap = 1'b0;
        foreach (pma_regions[j]) begin
          if (pma_region_base <= pma_regions[j].last &&
              pma_region_base + pma_region_size - 1 >= pma_regions[j].base)
            overlap = 1'b1;
        end
      end
      if (overlap)
        `uvm_fatal(get_type_name(), "failed to generate non-overlapping PMA segments")

      if ((i == pma_region_count - 1) && !have_cacheable)
        pma_region_cacheability = HPDCACHE_CACHEABLE;
      else if ((i == pma_region_count - 1) && !have_uncacheable)
        pma_region_cacheability = HPDCACHE_UNCACHEABLE;
      else if (!std::randomize(pma_region_cacheability) with {
        pma_region_cacheability dist {
          HPDCACHE_CACHEABLE := 3,
          HPDCACHE_UNCACHEABLE := 1
        };
      }) begin
        `uvm_fatal(get_type_name(), "failed to randomize the PMA region attribute")
      end
      have_cacheable |= pma_region_cacheability == HPDCACHE_CACHEABLE;
      have_uncacheable |= pma_region_cacheability == HPDCACHE_UNCACHEABLE;

      add_pma_region(
        hpdcache_req_addr_t'(pma_region_base),
        hpdcache_req_addr_t'(pma_region_base + pma_region_size - 1),
        pma_region_cacheability
      );
      `uvm_info("HPDCACHE_PMA_CFG", $sformatf(
        "pma_region[%0d] range=[0x%0h:0x%0h] size=%0dMiB cacheability=%s",
        i,
        hpdcache_req_addr_t'(pma_region_base),
        hpdcache_req_addr_t'(pma_region_base + pma_region_size - 1),
        pma_region_size >> 20,
        pma_region_cacheability.name()), UVM_LOW)
    end

    validate();
  endfunction

  function automatic int unsigned num_pma_regions();
    return pma_regions.size();
  endfunction

  // Return one configured PMA region. Set cacheable_only when required.
  function automatic pma_region_t random_pma_region(
    bit cacheable_only = 1'b0
  );
    int unsigned candidates[$];
    int unsigned selected;

    foreach (pma_regions[i]) begin
      if (!cacheable_only ||
          pma_regions[i].cacheability == HPDCACHE_CACHEABLE)
        candidates.push_back(i);
    end
    if (candidates.size() == 0)
      `uvm_fatal(get_type_name(), "no matching PMA region is configured")
    selected = $urandom_range(candidates.size() - 1, 0);
    return pma_regions[candidates[selected]];
  endfunction

  // Return the PMA region containing addr, if one exists.
  function automatic bit find_pma_region(
    hpdcache_req_addr_t addr,
    output pma_region_t pma_region
  );
    foreach (pma_regions[i]) begin
      if (addr inside {[pma_regions[i].base:pma_regions[i].last]}) begin
        pma_region = pma_regions[i];
        return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  function automatic bit is_mapped(hpdcache_req_addr_t addr);
    pma_region_t pma_region;
    return find_pma_region(addr, pma_region);
  endfunction

  function automatic bit is_uncacheable(hpdcache_req_addr_t addr);
    pma_region_t pma_region;

    return find_pma_region(addr, pma_region) &&
           pma_region.cacheability == HPDCACHE_UNCACHEABLE;
  endfunction

  function void validate();
    if (pma_regions.size() == 0)
      `uvm_fatal(get_type_name(), "at least one PMA region is required")

    foreach (pma_regions[i]) begin
      if (pma_regions[i].base > pma_regions[i].last)
        `uvm_fatal(get_type_name(), $sformatf(
          "PMA region %0d has an inverted range [0x%0h:0x%0h]",
          i, pma_regions[i].base, pma_regions[i].last))
      if (pma_regions[i].base[HPDCACHE_CFG.clOffsetWidth-1:0] != '0 ||
          pma_regions[i].last[HPDCACHE_CFG.clOffsetWidth-1:0] != '1)
        `uvm_fatal(get_type_name(), $sformatf(
          "PMA region %0d must be HPDcache cacheline aligned", i))
      for (int j = 0; j < i; j++) begin
        if (pma_regions[i].base <= pma_regions[j].last &&
            pma_regions[j].base <= pma_regions[i].last)
          `uvm_fatal(get_type_name(), $sformatf(
            "PMA regions %0d and %0d overlap", j, i))
      end
    end
  endfunction
endclass
