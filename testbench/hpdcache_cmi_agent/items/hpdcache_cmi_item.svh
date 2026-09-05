class hpdcache_cmi_item extends memory_txn#(
  MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH
);
  // The vendor base class copies only its two timing configuration fields.
  `uvm_object_utils_begin(hpdcache_cmi_item)
    `uvm_field_int(id, UVM_DEFAULT | UVM_HEX)
    `uvm_field_int(addr, UVM_DEFAULT | UVM_HEX)
    `uvm_field_int(data, UVM_DEFAULT | UVM_HEX)
    `uvm_field_int(strb, UVM_DEFAULT | UVM_HEX)
    `uvm_field_int(err, UVM_DEFAULT)
    `uvm_field_int(ex_fail, UVM_DEFAULT)
    `uvm_field_enum(mem_command_t, cmd, UVM_DEFAULT)
    `uvm_field_enum(mem_atomic_t, atop, UVM_DEFAULT)
    `uvm_field_int(req_ts, UVM_DEFAULT | UVM_DEC)
    `uvm_field_int(resp_ts, UVM_DEFAULT | UVM_DEC)
  `uvm_object_utils_end

  function new(string name = "hpdcache_cmi_item");
    super.new(name);
  endfunction
endclass
