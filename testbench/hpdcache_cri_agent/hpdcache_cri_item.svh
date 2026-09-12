// CRI channel items are specialized views of one transaction item.  Keeping
// the request and response fields in the common item preserves the existing
// sequence/driver API while allowing the monitor to publish strongly typed
// channel objects as well as a paired transaction object.
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
  bit                sc_expect_cmi_valid;
  bit                sc_expect_cmi;

  // data remains the request payload after transaction assembly.
  hpdcache_req_data_t response_data;

  bit                  constrain_addr_range;
  hpdcache_req_addr_t  addr_range_base;
  hpdcache_req_addr_t  addr_range_last;
  bit                  pma_uncacheable;

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

  // Keep ordinary traffic dominant while exercising every AMO and CMO in the
  // default random regression.
  constraint default_operation_c {
    soft op dist {
      HPDCACHE_REQ_LOAD                  := 45,
      HPDCACHE_REQ_STORE                 := 30,
      HPDCACHE_REQ_AMO_LR                := 1,
      HPDCACHE_REQ_AMO_SC                := 1,
      HPDCACHE_REQ_AMO_SWAP              := 1,
      HPDCACHE_REQ_AMO_ADD               := 1,
      HPDCACHE_REQ_AMO_AND               := 1,
      HPDCACHE_REQ_AMO_OR                := 1,
      HPDCACHE_REQ_AMO_XOR               := 1,
      HPDCACHE_REQ_AMO_MAX               := 1,
      HPDCACHE_REQ_AMO_MAXU              := 1,
      HPDCACHE_REQ_AMO_MIN               := 1,
      HPDCACHE_REQ_AMO_MINU              := 1,
      HPDCACHE_REQ_CMO_FENCE             := 1,
      HPDCACHE_REQ_CMO_PREFETCH          := 1,
      HPDCACHE_REQ_CMO_INVAL_NLINE       := 1,
      HPDCACHE_REQ_CMO_INVAL_ALL         := 1,
      HPDCACHE_REQ_CMO_FLUSH_NLINE       := 1,
      HPDCACHE_REQ_CMO_FLUSH_ALL         := 1,
      HPDCACHE_REQ_CMO_FLUSH_INVAL_NLINE := 1,
      HPDCACHE_REQ_CMO_FLUSH_INVAL_ALL   := 1
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

  constraint configured_addr_range_c {
    if (constrain_addr_range) {
      addr inside {[addr_range_base:addr_range_last]};
      pma.uncacheable == pma_uncacheable;
      if (!is_cmo(op))
        addr <= addr_range_last - ((1 << size) - 1);
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
    `uvm_field_int(sc_expect_cmi_valid, UVM_DEFAULT)
    `uvm_field_int(sc_expect_cmi, UVM_DEFAULT)
    `uvm_field_int(response_data, UVM_HEX)
  `uvm_object_utils_end

  function new(string name = "hpdcache_cri_item");
    super.new(name);
  endfunction

endclass

// Channel-specific objects intentionally add no fields.  Their distinct
// dynamic types let analysis subscribers state whether they consume request,
// response, or paired transaction traffic.
class hpdcache_cri_req_item extends hpdcache_cri_item;
  `uvm_object_utils(hpdcache_cri_req_item)

  function new(string name = "hpdcache_cri_req_item");
    super.new(name);
  endfunction
endclass

class hpdcache_cri_resp_item extends hpdcache_cri_item;
  `uvm_object_utils(hpdcache_cri_resp_item)

  function new(string name = "hpdcache_cri_resp_item");
    super.new(name);
  endfunction
endclass
