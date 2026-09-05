class hpdcache_cri_item extends uvm_sequence_item;
  localparam int unsigned REQ_BYTES = REQ_WORDS * (WORD_WIDTH / 8);

  rand hpdcache_req_op_t   op;
  rand hpdcache_req_addr_t addr;
  rand hpdcache_req_data_t data;
  rand hpdcache_req_be_t   be;
  rand hpdcache_req_size_t size;
  rand bit                 need_rsp;
  rand bit                 phys_indexed;
  rand hpdcache_pma_t      pma;
  rand bit                 abort;
  rand int unsigned        delay;

  hpdcache_req_sid_t sid;
  hpdcache_req_tid_t tid;
  bit                is_response;
  bit                error;
  bit                aborted;
  hpdcache_req_be_t  data_valid;

  bit                  use_pma_region;
  int unsigned         pma_region_index;
  hpdcache_req_addr_t  pma_region_base;
  hpdcache_req_addr_t  pma_region_last;
  bit                  pma_region_uncacheable;

  constraint legal_operation_c {
    op inside {
      HPDCACHE_REQ_LOAD,
      HPDCACHE_REQ_STORE,
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
      HPDCACHE_REQ_AMO_MINU,
      HPDCACHE_REQ_CMO_FENCE,
      HPDCACHE_REQ_CMO_PREFETCH,
      HPDCACHE_REQ_CMO_INVAL_NLINE,
      HPDCACHE_REQ_CMO_INVAL_ALL,
      HPDCACHE_REQ_CMO_FLUSH_NLINE,
      HPDCACHE_REQ_CMO_FLUSH_ALL,
      HPDCACHE_REQ_CMO_FLUSH_INVAL_NLINE,
      HPDCACHE_REQ_CMO_FLUSH_INVAL_ALL
    };
  }

  // The default regression exercises the ordinary CRI path.  Directed
  // sequences can override this soft constraint without using another item.
  constraint default_operation_c {
    soft op dist {
      HPDCACHE_REQ_LOAD  := 50,
      HPDCACHE_REQ_STORE := 50
    };
  }

  constraint legal_size_and_alignment_c {
    if (op inside {
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
        }) {
      size inside {2, 3};
      (addr % (1 << size)) == 0;
      be[0] == ((((1 << (1 << size)) - 1)) <<
                addr[$clog2(REQ_BYTES)-1:0]);
      need_rsp == 1'b1;
    } else if (op inside {HPDCACHE_REQ_LOAD, HPDCACHE_REQ_STORE}) {
      size inside {[0:$clog2(REQ_BYTES)]};
      (addr % (1 << size)) == 0;
      (be[0] & ~((((1 << (1 << size)) - 1)) <<
                 addr[$clog2(REQ_BYTES)-1:0])) == '0;
    } else if (op == HPDCACHE_REQ_CMO_PREFETCH) {
      size inside {[0:$clog2(REQ_BYTES)]};
      (addr % (1 << size)) == 0;
    }
  }

  constraint legal_attributes_c {
    pma.io == 1'b0;
    pma.wr_policy_hint inside {
      HPDCACHE_WR_POLICY_AUTO,
      HPDCACHE_WR_POLICY_WB,
      HPDCACHE_WR_POLICY_WT
    };
    abort -> !phys_indexed;
  }

  constraint configured_pma_region_c {
    if (use_pma_region) {
      addr inside {[pma_region_base:pma_region_last]};
      pma.uncacheable == pma_region_uncacheable;
    }
  }

  constraint default_distribution_c {
    soft need_rsp dist {1'b1 := 95, 1'b0 := 5};
    soft phys_indexed dist {1'b1 := 50, 1'b0 := 50};
    soft abort dist {1'b0 := 95, 1'b1 := 5};
    soft pma.uncacheable dist {1'b0 := 75, 1'b1 := 25};
    soft pma.wr_policy_hint dist {
      HPDCACHE_WR_POLICY_AUTO := 34,
      HPDCACHE_WR_POLICY_WB   := 33,
      HPDCACHE_WR_POLICY_WT   := 33
    };
  }

  constraint default_delay_c {
    soft delay inside {[0:10]};
  }

  `uvm_object_utils_begin(hpdcache_cri_item)
    `uvm_field_enum(hpdcache_req_op_t, op, UVM_DEFAULT)
    `uvm_field_int(addr, UVM_HEX)
    `uvm_field_int(data, UVM_HEX)
    `uvm_field_int(be, UVM_HEX)
    `uvm_field_int(size, UVM_DEC)
    `uvm_field_int(need_rsp, UVM_DEFAULT)
    `uvm_field_int(phys_indexed, UVM_DEFAULT)
    `uvm_field_int(pma, UVM_DEFAULT)
    `uvm_field_int(abort, UVM_DEFAULT)
    `uvm_field_int(delay, UVM_DEC)
    `uvm_field_int(sid, UVM_DEC)
    `uvm_field_int(tid, UVM_DEC)
    `uvm_field_int(is_response, UVM_DEFAULT)
    `uvm_field_int(error, UVM_DEFAULT)
    `uvm_field_int(aborted, UVM_DEFAULT)
    `uvm_field_int(data_valid, UVM_HEX)
  `uvm_object_utils_end

  function new(string name = "hpdcache_cri_item");
    super.new(name);
  endfunction

  function void select_pma_region(
    hpdcache_pma_config pma_config,
    int unsigned index
  );
    if (pma_config == null || index >= pma_config.num_regions())
      `uvm_fatal(get_type_name(), "invalid PMA region selection")
    use_pma_region          = 1'b1;
    pma_region_index        = index;
    pma_region_base         = pma_config.region_base(index);
    pma_region_last         = pma_config.region_last(index);
    pma_region_uncacheable = pma_config.region_is_uncacheable(index);
  endfunction
endclass
