// Reset-aware wrapper for the AXI adapter.  Worker-local burst state is
// discarded by killing and restarting the workers around every rstn pulse.
class hpdcache_axi2mem extends axi2mem #(
  MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH, 1
);
  `uvm_component_utils(hpdcache_axi2mem)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    // Workers are owned by run_phase so runtime reset can terminate them.
  endtask

  virtual task run_phase(uvm_phase phase);
    forever begin
      wait (axi_vif.rstn === 1'b1);
      fork
        write_aw_chan_fifo();
        write_w_chan_fifo();
        create_mem_req_from_aw_w_chan_fifo();
        convert_aw_w_chan_to_mem_req();
        write_ar_chan_fifo();
        convert_ar_chan_to_mem_req();
        write_b_chan_fifo();
        convert_b_chan_to_mem_intf();
        write_r_chan_fifo();
        convert_r_chan_to_mem_intf();
        wait (axi_vif.rstn !== 1'b1);
      join_any
      disable fork;
      clear_runtime_state();
    end
  endtask

  protected function void clear_runtime_state();
    axi_vif.b_valid = 1'b0;
    axi_vif.r_valid = 1'b0;
    mem_rd_vif.req_valid = 1'b0;
    mem_wr_vif.req_valid = 1'b0;
    mb_ar_chan.delete();
    mb_r_chan.delete();
    mb_aw_chan.delete();
    mb_w_chan.delete();
    mb_aw_w_chan.delete();
    mb_b_chan.delete();
    q_num_aw_chan_req.delete();
    q_num_ar_chan_req.delete();
  endfunction

  function bit is_idle();
    foreach (q_num_aw_chan_req[id])
      if (q_num_aw_chan_req[id].size() != 0) return 1'b0;
    foreach (q_num_ar_chan_req[id])
      if (q_num_ar_chan_req[id].size() != 0) return 1'b0;
    return mb_ar_chan.size() == 0 && mb_r_chan.size() == 0 &&
           mb_aw_chan.size() == 0 && mb_w_chan.size() == 0 &&
           mb_aw_w_chan.size() == 0 && mb_b_chan.size() == 0 &&
           axi_vif.b_valid !== 1'b1 && axi_vif.r_valid !== 1'b1 &&
           mem_rd_vif.req_valid !== 1'b1 && mem_wr_vif.req_valid !== 1'b1;
  endfunction
endclass
