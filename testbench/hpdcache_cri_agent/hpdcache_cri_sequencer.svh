// The sequencer exposes its agent configuration to sequences started on it.
class hpdcache_cri_sequencer extends uvm_sequencer #(hpdcache_cri_item);
  `uvm_component_utils(hpdcache_cri_sequencer)

  localparam int unsigned NUM_TIDS = 1 << REQ_TRANS_ID_WIDTH;

  hpdcache_cri_agent_config cfg;
  protected mailbox #(hpdcache_req_tid_t) available_tids;
  protected bit [NUM_TIDS-1:0] allocated_tids;
  protected int unsigned acquired_tids;
  protected int unsigned released_tids;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    available_tids = new(NUM_TIDS);
    initialize_tid_pool();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(hpdcache_cri_agent_config)::get(this, "", "cfg", cfg) ||
        cfg == null)
      `uvm_fatal(get_type_name(), "hpdcache_cri_agent_config was not configured")
  endfunction

  task acquire_tid(output hpdcache_req_tid_t tid);
    int unsigned tid_index;

    available_tids.get(tid);
    tid_index = int'(tid);
    if (allocated_tids[tid_index])
      `uvm_fatal(get_type_name(), $sformatf(
        "TID %0d was allocated twice", tid_index))
    allocated_tids[tid_index] = 1'b1;
    acquired_tids++;
  endtask

  function void release_tid(hpdcache_req_tid_t tid);
    int unsigned tid_index;

    tid_index = int'(tid);
    if (!allocated_tids[tid_index]) begin
      `uvm_error("HPDCACHE_CHK_TID", $sformatf(
        "TID %0d was released without being allocated", tid_index))
      return;
    end
    allocated_tids[tid_index] = 1'b0;
    released_tids++;
    if (!available_tids.try_put(tid))
      `uvm_fatal(get_type_name(), $sformatf(
        "TID mailbox is full while releasing TID %0d", tid_index))
  endfunction

  function void reset_tid_pool();
    hpdcache_req_tid_t discarded_tid;

    while (available_tids.try_get(discarded_tid)) begin
    end
    allocated_tids = '0;
    for (int unsigned i = 0; i < NUM_TIDS; i++) begin
      if (!available_tids.try_put(hpdcache_req_tid_t'(i)))
        `uvm_fatal(get_type_name(), "failed to repopulate TID mailbox")
    end
  endfunction

  function automatic bit is_idle();
    return available_tids.num() == NUM_TIDS;
  endfunction

  function automatic int unsigned num_outstanding();
    return NUM_TIDS - available_tids.num();
  endfunction

  protected function void initialize_tid_pool();
    allocated_tids = '0;
    for (int unsigned i = 0; i < NUM_TIDS; i++) begin
      if (!available_tids.try_put(hpdcache_req_tid_t'(i)))
        `uvm_fatal(get_type_name(), "failed to initialize TID mailbox")
    end
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info(get_type_name(), $sformatf(
      "TIDs acquired=%0d released=%0d outstanding=%0d",
      acquired_tids, released_tids, num_outstanding()), UVM_LOW)
  endfunction
endclass
