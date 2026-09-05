class hpdcache_cmi_monitor extends uvm_monitor;
  `uvm_component_utils(hpdcache_cmi_monitor)

  typedef memory_txn#(MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH) mem_item_t;

  virtual hpdcache_cmi_if vif;
  uvm_analysis_port #(mem_item_t) request_ap;
  uvm_analysis_port #(mem_item_t) response_ap;

  protected hpdcache_mem_req_t write_address_q[$];
  protected hpdcache_mem_req_w_t write_data_q[$];
  protected int unsigned observed_requests;
  protected int unsigned observed_responses;
  protected int unsigned assembled_writes;
  protected int unsigned pending_read_beats;
  protected int unsigned pending_write_responses;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    request_ap = new("request_ap", this);
    response_ap = new("response_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual hpdcache_cmi_if)::get(this, "", "vif", vif))
      `uvm_fatal(get_type_name(), "hpdcache_cmi_if was not configured")
  endfunction

  virtual task run_phase(uvm_phase phase);
    super.run_phase(phase);
    forever begin
      @(vif.mon_cb);
      if (!vif.mon_cb.rst_ni) begin
        reset_state();
        continue;
      end

      if (vif.mon_cb.mem_req_read_valid && vif.mon_cb.mem_req_read_ready)
        sample_read_request(vif.mon_cb.mem_req_read);
      if (vif.mon_cb.mem_req_write_valid && vif.mon_cb.mem_req_write_ready) begin
        write_address_q.push_back(vif.mon_cb.mem_req_write);
        pending_write_responses++;
      end
      if (vif.mon_cb.mem_req_write_data_valid &&
          vif.mon_cb.mem_req_write_data_ready)
        write_data_q.push_back(vif.mon_cb.mem_req_write_data);
      complete_write_requests();

      if (vif.mon_cb.mem_rsp_read_valid && vif.mon_cb.mem_rsp_read_ready)
        sample_read_response(vif.mon_cb.mem_rsp_read);
      if (vif.mon_cb.mem_rsp_write_valid && vif.mon_cb.mem_rsp_write_ready)
        sample_write_response(vif.mon_cb.mem_rsp_write);
    end
  endtask

  protected function automatic bit [MEM_DATA_WIDTH/8-1:0] transfer_mask(
    hpdcache_mem_req_t request
  );
    bit [MEM_DATA_WIDTH/8-1:0] mask;
    int unsigned byte_count;
    int unsigned byte_offset;

    byte_count = 1 << request.mem_req_size;
    byte_offset = request.mem_req_addr % (MEM_DATA_WIDTH / 8);
    mask = '0;
    for (int unsigned i = 0; i < byte_count; i++)
      mask[byte_offset + i] = 1'b1;
    return mask;
  endfunction

  protected function automatic mem_command_t convert_command(
    hpdcache_mem_command_e command
  );
    case (command)
      HPDCACHE_MEM_READ:   return MEM_READ;
      HPDCACHE_MEM_WRITE:  return MEM_WRITE;
      HPDCACHE_MEM_ATOMIC: return MEM_ATOMIC;
      default:             return MEM_READ;
    endcase
  endfunction

  protected function mem_item_t make_request(
    hpdcache_mem_req_t request,
    hpdcache_mem_req_w_t write_data,
    bit is_write
  );
    mem_item_t item;

    item = hpdcache_cmi_item::type_id::create("observed_cmi_request");
    item.id = request.mem_req_id;
    item.addr = request.mem_req_addr;
    item.data = is_write ? write_data.mem_req_w_data : '0;
    item.strb = is_write ? write_data.mem_req_w_be : transfer_mask(request);
    item.err = 1'b0;
    item.cmd = convert_command(request.mem_req_command);
    item.atop = mem_atomic_t'(request.mem_req_atomic);
    return item;
  endfunction

  protected function void sample_read_request(hpdcache_mem_req_t request);
    mem_item_t item;

    pending_read_beats += int'(request.mem_req_len) + 1;
    if (request.mem_req_cacheable)
      return;
    item = make_request(request, '0, 1'b0);
    observed_requests++;
    request_ap.write(item);
  endfunction

  protected function void complete_write_requests();
    hpdcache_mem_req_t request;
    hpdcache_mem_req_w_t write_data;
    mem_item_t item;
    int unsigned beats;

    while (write_address_q.size() != 0 && write_data_q.size() != 0) begin
      beats = int'(write_address_q[0].mem_req_len) + 1;
      if (write_data_q.size() < beats)
        return;
      request = write_address_q.pop_front();
      // W has no ID: consume the full burst in AW order, including writes
      // that will be filtered out, before pairing the next address.
      for (int unsigned i = 0; i < beats; i++) begin
        write_data = write_data_q.pop_front();
        if (write_data.mem_req_w_last !== (i == beats - 1))
          `uvm_error("HPDCACHE_CHK_CMI", $sformatf(
            "write burst LAST mismatch addr=0x%0h beat=%0d len=%0d last=%0b",
            request.mem_req_addr, i, request.mem_req_len,
            write_data.mem_req_w_last))
      end
      assembled_writes++;
      if (request.mem_req_cacheable)
        continue;
      if (beats != 1) begin
        `uvm_error("HPDCACHE_CHK_CMI", $sformatf(
          "uncacheable write must be single-beat addr=0x%0h len=%0d",
          request.mem_req_addr, request.mem_req_len))
        continue;
      end
      item = make_request(request, write_data, 1'b1);
      observed_requests++;
      request_ap.write(item);
    end
  endfunction

  protected function void sample_read_response(hpdcache_mem_resp_r_t response);
    mem_item_t item;

    if (pending_read_beats == 0) begin
      `uvm_error("HPDCACHE_CHK_CMI", "read response has no pending read request")
    end else begin
      pending_read_beats--;
    end
    if (response.mem_resp_r_id !== {MEM_ID_WIDTH{1'b1}})
      return;
    item = hpdcache_cmi_item::type_id::create("observed_cmi_read_response");
    item.id = response.mem_resp_r_id;
    item.data = response.mem_resp_r_data;
    item.err = response.mem_resp_r_error != HPDCACHE_MEM_RESP_OK;
    item.cmd = MEM_READ;
    observed_responses++;
    response_ap.write(item);
  endfunction

  protected function void sample_write_response(hpdcache_mem_resp_w_t response);
    mem_item_t item;

    if (pending_write_responses == 0) begin
      `uvm_error("HPDCACHE_CHK_CMI", "write response has no pending write request")
    end else begin
      pending_write_responses--;
    end
    if (response.mem_resp_w_id !== {MEM_ID_WIDTH{1'b1}})
      return;
    item = hpdcache_cmi_item::type_id::create("observed_cmi_write_response");
    item.id = response.mem_resp_w_id;
    item.err = response.mem_resp_w_error != HPDCACHE_MEM_RESP_OK;
    item.cmd = MEM_WRITE;
    observed_responses++;
    response_ap.write(item);
  endfunction

  function void reset_state();
    write_address_q.delete();
    write_data_q.delete();
    pending_read_beats = 0;
    pending_write_responses = 0;
  endfunction

  function automatic bit is_idle();
    return write_address_q.size() == 0 &&
           write_data_q.size() == 0 &&
           pending_read_beats == 0 &&
           pending_write_responses == 0;
  endfunction

  virtual function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (!is_idle())
      `uvm_error("HPDCACHE_CHK_CMI", $sformatf(
        "CMI monitor ended with pending write_addr=%0d write_data=%0d read_beats=%0d write_responses=%0d",
        write_address_q.size(), write_data_q.size(), pending_read_beats,
        pending_write_responses))
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("HPDCACHE_RPT_TRAFFIC_CMI", $sformatf(
      "requests=%0d responses=%0d",
      observed_requests, observed_responses), UVM_NONE)
    `uvm_info("HPDCACHE_RPT_CHECK_CMI", $sformatf(
      "writes_assembled=%0d pending_write_addr=%0d pending_write_data=%0d pending_read_beats=%0d pending_write_responses=%0d",
      assembled_writes, write_address_q.size(), write_data_q.size(),
      pending_read_beats, pending_write_responses), UVM_NONE)
  endfunction
endclass
