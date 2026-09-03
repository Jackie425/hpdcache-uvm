class hpdcache_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(hpdcache_scoreboard)

  uvm_analysis_export #(hpdcache_item) request_export;
  uvm_analysis_export #(hpdcache_item) actual_export;
  uvm_analysis_export #(
    memory_txn#(MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH)
  ) memory_response_export;

  hpdcache_predictor predictor;
  hpdcache_evaluator evaluator;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    request_export = new("request_export", this);
    actual_export = new("actual_export", this);
    memory_response_export = new("memory_response_export", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    predictor = hpdcache_predictor::type_id::create("predictor", this);
    evaluator = hpdcache_evaluator::type_id::create("evaluator", this);
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    request_export.connect(predictor.request_imp);
    memory_response_export.connect(predictor.memory_response_imp);
    predictor.expected_port.connect(evaluator.expected_imp);
    actual_export.connect(evaluator.actual_imp);
  endfunction

  function automatic bit is_idle();
    return predictor.is_idle() && evaluator.is_idle();
  endfunction

  function automatic string drain_status();
    return $sformatf("predictor_idle=%0b evaluator_idle=%0b",
                     predictor.is_idle(), evaluator.is_idle());
  endfunction

endclass
