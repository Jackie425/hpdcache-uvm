class hpdcache_random_seq extends uvm_sequence #(hpdcache_cri_item);
  `uvm_object_utils(hpdcache_random_seq)
  `uvm_declare_p_sequencer(hpdcache_cri_sequencer)

  int unsigned item_num;

  function new(string name = "hpdcache_random_seq");
    super.new(name);
  endfunction

  task body();
    if (p_sequencer == null)
      `uvm_fatal(get_type_name(), "worker sequence has no CRI sequencer")
    if (item_num == 0)
      `uvm_fatal(get_type_name(), "item_num was not configured")

    for (int unsigned i = 0; i < item_num; i++) begin
      automatic int unsigned sequence_index = i;
      fork
        begin
          hpdcache_random_seq_api api_seq;

          api_seq = hpdcache_random_seq_api::type_id::create(
            $sformatf("random_api_seq_%0d", sequence_index)
          );
          api_seq.start(p_sequencer, this);
        end
      join_none
    end
    wait fork;
  endtask
endclass
