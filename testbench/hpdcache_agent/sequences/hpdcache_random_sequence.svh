class hpdcache_random_sequence extends hpdcache_base_sequence;
  `uvm_object_utils(hpdcache_random_sequence)

  function new(string name = "hpdcache_random_sequence");
    super.new(name);
  endfunction

  task body();
    hpdcache_item item;

    begin_request("random_item", item);
    if (!item.randomize())
      `uvm_fatal(get_type_name(), "failed to randomize the item")
    end_request(item);
  endtask
endclass
