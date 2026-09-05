// CMI transactions are owned by this testbench.  They deliberately do not
// derive from the vendor memory transaction base: a CMI item contains both
// sides of one memory transaction and is completed by the CMI monitor.
class hpdcache_cmi_item extends uvm_sequence_item;
  bit [MEM_ID_WIDTH-1:0]   id;
  bit [MEM_ADDR_WIDTH-1:0] addr;
  bit [MEM_DATA_WIDTH-1:0] request_data;
  bit [MEM_DATA_WIDTH/8-1:0] request_strb;
  bit [MEM_DATA_WIDTH-1:0] response_data;
  bit                       err;
  bit                       request_valid;
  bit                       response_valid;
  bit                       request_cacheable;
  mem_command_t             cmd;
  mem_atomic_t              atop;

  `uvm_object_utils_begin(hpdcache_cmi_item)
    `uvm_field_int(id, UVM_DEFAULT | UVM_HEX)
    `uvm_field_int(addr, UVM_DEFAULT | UVM_HEX)
    `uvm_field_int(request_data, UVM_DEFAULT | UVM_HEX)
    `uvm_field_int(request_strb, UVM_DEFAULT | UVM_HEX)
    `uvm_field_int(response_data, UVM_DEFAULT | UVM_HEX)
    `uvm_field_int(err, UVM_DEFAULT)
    `uvm_field_int(request_valid, UVM_DEFAULT)
    `uvm_field_int(response_valid, UVM_DEFAULT)
    `uvm_field_int(request_cacheable, UVM_DEFAULT)
    `uvm_field_enum(mem_command_t, cmd, UVM_DEFAULT)
    `uvm_field_enum(mem_atomic_t, atop, UVM_DEFAULT)
  `uvm_object_utils_end

  function new(string name = "hpdcache_cmi_item");
    super.new(name);
  endfunction
endclass

class hpdcache_cmi_read_item extends hpdcache_cmi_item;
  `uvm_object_utils(hpdcache_cmi_read_item)

  function new(string name = "hpdcache_cmi_read_item");
    super.new(name);
  endfunction
endclass

class hpdcache_cmi_write_item extends hpdcache_cmi_item;
  `uvm_object_utils(hpdcache_cmi_write_item)

  function new(string name = "hpdcache_cmi_write_item");
    super.new(name);
  endfunction
endclass
