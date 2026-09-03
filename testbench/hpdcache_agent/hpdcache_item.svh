class hpdcache_item extends uvm_sequence_item;
  rand hpdcache_req_op_t   op;
  rand hpdcache_req_addr_t addr;
  rand hpdcache_req_data_t data;
  rand hpdcache_req_be_t   be;
  rand hpdcache_req_size_t size;

  hpdcache_req_sid_t sid;
  hpdcache_req_tid_t tid;
  bit                is_response;
  bit                error;
  // Per-byte validity of expected load data.  A zero bit means that the
  // shadow memory has not yet learned that byte from a store or a memory
  // read response, so the scoreboard must not compare it.
  hpdcache_req_be_t  data_valid;

  constraint load_store_only_c { op inside {HPDCACHE_REQ_LOAD, HPDCACHE_REQ_STORE}; }
  constraint random_region_c {
    addr inside {[hpdcache_req_addr_t'(56'h00000080000000):
                  hpdcache_req_addr_t'(56'h00000080000ff8)]};
    addr[2:0] == 3'b000;
  }
  constraint full_word_c {
    size == hpdcache_req_size_t'(3);
    be == '1;
  }

  `uvm_object_utils_begin(hpdcache_item)
    `uvm_field_enum(hpdcache_req_op_t, op, UVM_DEFAULT)
    `uvm_field_int(addr, UVM_HEX)
    `uvm_field_int(data, UVM_HEX)
    `uvm_field_int(be, UVM_HEX)
    `uvm_field_int(size, UVM_DEC)
    `uvm_field_int(sid, UVM_DEC)
    `uvm_field_int(tid, UVM_DEC)
    `uvm_field_int(is_response, UVM_DEFAULT)
    `uvm_field_int(error, UVM_DEFAULT)
    `uvm_field_int(data_valid, UVM_HEX)
  `uvm_object_utils_end

  function new(string name = "hpdcache_item");
    super.new(name);
  endfunction
endclass
