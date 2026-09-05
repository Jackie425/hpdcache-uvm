class hpdcache_base_vseq extends uvm_sequence;
  `uvm_object_utils(hpdcache_base_vseq)

  hpdcache_cri_sequencer cri_sequencers[$];

  function new(string name = "hpdcache_base_vseq");
    super.new(name);
  endfunction

  virtual task pre_start();
    super.pre_start();
    if (cri_sequencers.size() == 0)
      `uvm_fatal(get_type_name(), "no CRI sequencer was configured")
    foreach (cri_sequencers[i]) begin
      if (cri_sequencers[i] == null)
        `uvm_fatal(get_type_name(), $sformatf(
          "cri_sequencers[%0d] is null", i))
    end
  endtask
endclass
