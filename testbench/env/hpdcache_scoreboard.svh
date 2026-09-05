class hpdcache_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(hpdcache_scoreboard)

  typedef memory_txn#(MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH) mem_item_t;

  uvm_analysis_export #(hpdcache_cri_item) request_export;
  uvm_analysis_export #(hpdcache_cri_item) response_export;
  uvm_analysis_export #(mem_item_t) memory_read_response_export;
  uvm_analysis_export #(mem_item_t) cmi_request_export;
  uvm_analysis_export #(mem_item_t) cmi_response_export;

  hpdcache_pma_config pma_cfg;
  hpdcache_predictor predictor;
  hpdcache_cacheable_evaluator cacheable_evaluator;
  hpdcache_uncacheable_evaluator uncacheable_evaluator;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    request_export = new("request_export", this);
    response_export = new("response_export", this);
    memory_read_response_export = new("memory_read_response_export", this);
    cmi_request_export = new("cmi_request_export", this);
    cmi_response_export = new("cmi_response_export", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(hpdcache_pma_config)::get(
          this, "", "pma_cfg", pma_cfg) || pma_cfg == null)
      `uvm_fatal(get_type_name(), "hpdcache_pma_config was not configured")

    uvm_config_db#(hpdcache_pma_config)::set(
      this, "predictor", "pma_cfg", pma_cfg
    );
    uvm_config_db#(hpdcache_pma_config)::set(
      this, "cacheable_evaluator", "pma_cfg", pma_cfg
    );
    uvm_config_db#(hpdcache_pma_config)::set(
      this, "uncacheable_evaluator", "pma_cfg", pma_cfg
    );
    predictor = hpdcache_predictor::type_id::create("predictor", this);
    cacheable_evaluator = hpdcache_cacheable_evaluator::type_id::create(
      "cacheable_evaluator", this
    );
    uncacheable_evaluator =
      hpdcache_uncacheable_evaluator::type_id::create(
        "uncacheable_evaluator", this
      );
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    request_export.connect(predictor.request_imp);
    request_export.connect(uncacheable_evaluator.cri_request_imp);
    memory_read_response_export.connect(predictor.memory_response_imp);
    predictor.expected_port.connect(cacheable_evaluator.expected_imp);
    response_export.connect(cacheable_evaluator.actual_imp);
    response_export.connect(uncacheable_evaluator.cri_response_imp);
    cmi_request_export.connect(uncacheable_evaluator.cmi_request_imp);
    cmi_response_export.connect(uncacheable_evaluator.cmi_response_imp);
  endfunction

  function automatic bit is_idle();
    return predictor.is_idle() &&
           cacheable_evaluator.is_idle() &&
           uncacheable_evaluator.is_idle();
  endfunction

  function automatic string drain_status();
    return $sformatf(
      "predictor_idle=%0b cacheable_evaluator_idle=%0b uncacheable_evaluator_idle=%0b",
      predictor.is_idle(), cacheable_evaluator.is_idle(),
      uncacheable_evaluator.is_idle()
    );
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info(get_type_name(), $sformatf(
      "final drain state: %s", drain_status()), UVM_LOW)
  endfunction
endclass
