// Transaction-ID allocator shared by sequences using one requester.
class hpdcache_tid_manager extends uvm_object;
  `uvm_object_utils(hpdcache_tid_manager)

  localparam int unsigned NUM_TIDS = 1 << REQ_TRANS_ID_WIDTH;

  protected mailbox #(hpdcache_req_tid_t) available_tids;
  protected bit [NUM_TIDS-1:0] allocated;

  function new(string name = "hpdcache_tid_manager");
    super.new(name);
    available_tids = new(NUM_TIDS);
    initialize_pool();
  endfunction

  task acquire_tid(output hpdcache_req_tid_t tid);
    int unsigned tid_index;

    // The mailbox atomically transfers ownership.  No process can interleave
    // between the blocking get returning and the zero-time bookkeeping below.
    available_tids.get(tid);

    tid_index = int'(tid);
    if (allocated[tid_index])
      `uvm_fatal(get_type_name(), $sformatf(
        "TID %0d was allocated twice", tid_index))
    allocated[tid_index] = 1'b1;
  endtask

  function void release_tid(hpdcache_req_tid_t tid);
    int unsigned tid_index;

    tid_index = int'(tid);
    if (tid_index >= NUM_TIDS) begin
      `uvm_error(get_type_name(), $sformatf(
        "attempted to release out-of-range TID %0d", tid_index))
      return;
    end

    if (!allocated[tid_index]) begin
      `uvm_error(get_type_name(), $sformatf(
        "TID %0d was released without being allocated", tid_index))
      return;
    end
    allocated[tid_index] = 1'b0;
    if (!available_tids.try_put(tid))
      `uvm_fatal(get_type_name(), $sformatf(
        "TID mailbox is full while releasing TID %0d", tid_index))
  endfunction

  function void reset_pool();
    hpdcache_req_tid_t discarded_tid;

    while (available_tids.try_get(discarded_tid)) begin
      // Drain stale entries before repopulating the bounded mailbox.
    end
    allocated = '0;
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

  protected function void initialize_pool();
    allocated = '0;
    for (int unsigned i = 0; i < NUM_TIDS; i++) begin
      if (!available_tids.try_put(hpdcache_req_tid_t'(i)))
        `uvm_fatal(get_type_name(), "failed to initialize TID mailbox")
    end
  endfunction
endclass

// Each requester agent receives a distinct instance of this configuration.
// Its TID manager is intentionally part of the configuration so every
// sequence started on that agent resolves the same allocator handle.
class hpdcache_agent_config extends uvm_object;
  `uvm_object_utils(hpdcache_agent_config)

  bit active = 1'b1;
  int unsigned requester_id;
  hpdcache_tid_manager tid_manager;

  function new(string name = "hpdcache_agent_config");
    super.new(name);
    tid_manager = hpdcache_tid_manager::type_id::create(
      {name, "_tid_manager"}
    );
  endfunction

  function void validate();
    if (requester_id >= (1 << REQ_SRC_ID_WIDTH))
      `uvm_fatal(get_type_name(), $sformatf(
        "requester_id %0d does not fit in the %0d-bit SID", requester_id,
        REQ_SRC_ID_WIDTH))
    if (tid_manager == null)
      `uvm_fatal(get_type_name(), "tid_manager was not created")
  endfunction
endclass
