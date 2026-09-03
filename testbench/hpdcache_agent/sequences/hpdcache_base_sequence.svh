class hpdcache_base_sequence extends uvm_sequence #(hpdcache_item);
  `uvm_object_utils(hpdcache_base_sequence)

  hpdcache_agent_config cfg;
  protected bit outstanding_tids[hpdcache_req_tid_t];

  function new(string name = "hpdcache_base_sequence");
    super.new(name);
    use_response_handler(1);
  endfunction

  virtual task pre_start();
    hpdcache_sequencer sequencer;

    super.pre_start();
    cfg = null;
    outstanding_tids.delete();
    if (!$cast(sequencer, m_sequencer))
      `uvm_fatal(get_type_name(), $sformatf(
        "sequence requires hpdcache_sequencer, got %s",
        m_sequencer == null ? "null" : m_sequencer.get_type_name()))
    cfg = sequencer.cfg;
    if (cfg == null)
      `uvm_fatal(get_type_name(), "sequencer has no hpdcache_agent_config")
  endtask

  protected task begin_request(
    string name,
    output hpdcache_item item
  );
    hpdcache_req_tid_t tid;

    if (cfg == null || cfg.tid_manager == null)
      `uvm_fatal(get_type_name(), $sformatf(
        "%s could not find its agent configuration",
        get_type_name()))

    cfg.tid_manager.acquire_tid(tid);
    item = hpdcache_item::type_id::create(name);
    start_item(item);
    item.sid = cfg.requester_id;
    item.tid = tid;
    outstanding_tids[tid] = 1'b1;
  endtask

  protected task end_request(hpdcache_item item);
    finish_item(item);
  endtask

  virtual function void response_handler(uvm_sequence_item response);
    hpdcache_item typed_response;

    if (response == null || !$cast(typed_response, response)) begin
      `uvm_error(get_type_name(), "received an invalid response")
      return;
    end
    if (!outstanding_tids.exists(typed_response.tid)) begin
      `uvm_error(get_type_name(), $sformatf(
        "received a response for non-outstanding TID %0d",
        int'(typed_response.tid)))
      return;
    end

    outstanding_tids.delete(typed_response.tid);
    cfg.tid_manager.release_tid(typed_response.tid);
  endfunction

  virtual task post_start();
    // Keep this sequence registered so the sequencer can route every response
    // to its handler.  Unlike post_body(), post_start() is always called.
    wait (outstanding_tids.num() == 0);
    super.post_start();
  endtask

  virtual task body();
    `uvm_fatal(get_type_name(), "hpdcache_base_sequence must be extended")
  endtask
endclass
