// Reset-aware wrapper for cv_dv_utils' response model.  The vendor model
// uses UVM phase events; this environment also supports runtime signal reset.
class hpdcache_memory_response_model extends memory_response_model #(
  MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH
);
  `uvm_component_utils(hpdcache_memory_response_model)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    forever begin
      wait (m_mem_rsp_vif.rstn === 1'b1);
      fork
        global_cycle_counter();
        schedule_and_drive_rd_response();
        schedule_and_drive_wr_response();
        populate_wr_rsp_queue();
        populate_rd_rsp_queue();
        populate_amo_rd_wr_rsp_queue();
        wait (m_mem_rsp_vif.rstn !== 1'b1);
      join_any
      disable fork;
      clear_runtime_state();
    end
  endtask

  protected function void clear_runtime_state();
    rd_rsp_queue.delete();
    wr_rsp_queue.delete();
    amo_reservation_queue.delete();
    foreach (m_memory[addr])
      m_memory[addr].ldex_bytes.delete();
    global_cycle_count = 0;
    rd_rsp_error_counter = 0;
    wr_rsp_error_counter = 0;
    wr_rsp_exclusive_fail_counter = 0;
    amo_rd_rsp_error_counter = 0;
    amo_wr_rsp_error_counter = 0;
    m_mem_rsp_vif.rd_res_valid = 1'b0;
    m_mem_rsp_vif.wr_res_valid = 1'b0;
  endfunction

  function bit is_idle();
    return rd_rsp_queue.size() == 0 && wr_rsp_queue.size() == 0 &&
           m_mem_rsp_vif.rd_res_valid !== 1'b1 &&
           m_mem_rsp_vif.wr_res_valid !== 1'b1;
  endfunction
endclass
