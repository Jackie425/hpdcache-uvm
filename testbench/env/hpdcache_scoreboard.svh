class hpdcache_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(hpdcache_scoreboard)

  uvm_analysis_export #(hpdcache_cri_req_item) cri_req_export;
  uvm_analysis_export #(hpdcache_cri_resp_item) cri_resp_export;
  uvm_analysis_export #(hpdcache_cri_item) cri_export;
  uvm_analysis_export #(hpdcache_cmi_read_item) cmi_read_export;
  uvm_analysis_export #(hpdcache_cmi_write_item) cmi_write_export;
  uvm_analysis_export #(hpdcache_cmi_atomic_item) cmi_atomic_export;
  uvm_analysis_export #(memory_txn#(
    MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH
  )) memory_read_response_export;

  hpdcache_pma_config pma_cfg;
  hpdcache_predictor predictor;
  hpdcache_cacheable_evaluator cacheable_evaluator;
  hpdcache_uc_amo_forwarding_evaluator uc_amo_forwarding_evaluator;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cri_req_export = new("cri_req_export", this);
    cri_resp_export = new("cri_resp_export", this);
    cri_export = new("cri_export", this);
    cmi_read_export = new("cmi_read_export", this);
    cmi_write_export = new("cmi_write_export", this);
    cmi_atomic_export = new("cmi_atomic_export", this);
    memory_read_response_export = new("memory_read_response_export", this);
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
      this, "uc_amo_forwarding_evaluator", "pma_cfg", pma_cfg
    );
    predictor = hpdcache_predictor::type_id::create("predictor", this);
    cacheable_evaluator = hpdcache_cacheable_evaluator::type_id::create(
      "cacheable_evaluator", this
    );
    uc_amo_forwarding_evaluator =
      hpdcache_uc_amo_forwarding_evaluator::type_id::create(
        "uc_amo_forwarding_evaluator", this
      );
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    cri_req_export.connect(predictor.request_imp);
    memory_read_response_export.connect(predictor.memory_response_imp);
    cri_export.connect(uc_amo_forwarding_evaluator.cri_item_imp);
    predictor.expected_port.connect(cacheable_evaluator.expected_imp);
    predictor.expected_port.connect(uc_amo_forwarding_evaluator.sc_expected_imp);
    cri_resp_export.connect(cacheable_evaluator.actual_imp);
    cmi_read_export.connect(uc_amo_forwarding_evaluator.cmi_read_item_imp);
    cmi_write_export.connect(uc_amo_forwarding_evaluator.cmi_write_item_imp);
    cmi_atomic_export.connect(uc_amo_forwarding_evaluator.cmi_atomic_item_imp);
    cmi_atomic_export.connect(predictor.cmi_atomic_imp);
  endfunction

  function automatic bit is_idle();
    return predictor.is_idle() &&
           cacheable_evaluator.is_idle() &&
           uc_amo_forwarding_evaluator.is_idle();
  endfunction

  function automatic string drain_status();
    return $sformatf(
      "predictor_idle=%0b cacheable_evaluator_idle=%0b uc_amo_forwarding_evaluator_idle=%0b",
      predictor.is_idle(), cacheable_evaluator.is_idle(),
      uc_amo_forwarding_evaluator.is_idle()
    );
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info(get_type_name(), $sformatf(
      "final drain state: %s", drain_status()), UVM_LOW)
  endfunction
endclass
