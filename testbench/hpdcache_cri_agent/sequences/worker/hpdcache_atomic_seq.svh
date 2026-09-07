class hpdcache_atomic_seq extends uvm_sequence #(hpdcache_cri_item);
  `uvm_object_utils(hpdcache_atomic_seq)
  `uvm_declare_p_sequencer(hpdcache_cri_sequencer)

  int unsigned item_num;
  rand bit start_lrsc;

  // Keep the LR/SC pair as a worker-level traffic choice.  The AMO opcode
  // itself remains owned by hpdcache_amo_seq_api and its constraints.
  constraint atomic_mix_c {
    soft start_lrsc dist {1'b0 := 4, 1'b1 := 1};
  }

  function new(string name = "hpdcache_atomic_seq");
    super.new(name);
  endfunction

  task body();
    hpdcache_lrsc_seq lrsc_seq;
    hpdcache_amo_seq_api amo_seq;
    int unsigned items_sent;

    if (p_sequencer == null)
      `uvm_fatal(get_type_name(), "atomic sequence has no CRI sequencer")
    if (item_num == 0)
      `uvm_fatal(get_type_name(), "item_num was not configured")

    items_sent = 0;
    while (items_sent < item_num) begin
      if (items_sent + 2 <= item_num) begin
        if (!randomize(start_lrsc))
          `uvm_fatal(get_type_name(),
            "failed to randomize the atomic worker choice")
      end else begin
        start_lrsc = 1'b0;
      end

      if (start_lrsc) begin
        lrsc_seq = hpdcache_lrsc_seq::type_id::create(
          $sformatf("lrsc_worker_%0d", items_sent)
        );
        lrsc_seq.max_inter_ops = item_num - items_sent - 2;
        if (!lrsc_seq.randomize())
          `uvm_fatal(get_type_name(),
            "failed to randomize the LR/SC intervening traffic")
        lrsc_seq.start(p_sequencer, this);
        items_sent += lrsc_seq.items_sent;
        continue;
      end

      amo_seq = hpdcache_amo_seq_api::type_id::create(
        $sformatf("amo_api_%0d", items_sent)
      );
      if (!amo_seq.randomize())
        `uvm_fatal(get_type_name(),
          "failed to randomize the AMO API constraints")
      amo_seq.start(p_sequencer, this);
      items_sent++;
    end
  endtask
endclass
