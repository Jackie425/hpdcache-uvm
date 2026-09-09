class hpdcache_reference_model extends uvm_object;
  `uvm_object_utils(hpdcache_reference_model)
  localparam int unsigned MEM_BYTES = MEM_DATA_WIDTH / 8;
  localparam int unsigned REQ_BYTES = REQ_WORDS * (WORD_WIDTH / 8);
  localparam int unsigned CACHELINE_BYTES = 1 << HPDCACHE_CFG.clOffsetWidth;

  typedef struct packed {
    logic [MEM_DATA_WIDTH-1:0] data;
    logic [MEM_BYTES-1:0]      valid;
  } memory_entry_t;
  memory_entry_t memory_table[longint unsigned];
  protected bit reservation_valid;
  protected longint unsigned reservation_word;

  function new(string name = "hpdcache_reference_model");
    super.new(name);
  endfunction

  function void ensure_entry(longint unsigned word_key);
    if (!memory_table.exists(word_key))
      memory_table[word_key] = '0;
  endfunction

  function void reset();
    memory_table.delete();
    reservation_valid = 1'b0;
    reservation_word = '0;
  endfunction

  // Mirror a completed downstream memory read in the golden memory.
  function bit apply_memory_response(
    memory_txn#(MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH) t
  );
    longint unsigned word_key;

    if (t.err)
      return 1'b0;
    word_key = longint'(t.addr) / MEM_BYTES;
    ensure_entry(word_key);
    for (int unsigned i = 0; i < MEM_BYTES; i++) begin
      if (!memory_table[word_key].valid[i]) begin
        memory_table[word_key].data[i*8 +: 8] = t.data[i*8 +: 8];
        memory_table[word_key].valid[i] = 1'b1;
      end
    end
    return 1'b1;
  endfunction

  function void write_byte(longint unsigned byte_addr, logic [7:0] data);
    longint unsigned word_key;
    int unsigned mem_byte;

    word_key = byte_addr / MEM_BYTES;
    mem_byte = byte_addr % MEM_BYTES;
    ensure_entry(word_key);
    memory_table[word_key].data[mem_byte*8 +: 8] = data;
    memory_table[word_key].valid[mem_byte] = 1'b1;
  endfunction

  function void clear_reservation_if_range_hit(
    longint unsigned byte_addr,
    int unsigned byte_count
  );
    longint unsigned first_word;
    longint unsigned last_word;

    if (!reservation_valid || byte_count == 0)
      return;
    first_word = byte_addr / 8;
    last_word = (byte_addr + byte_count - 1) / 8;
    if (reservation_word >= first_word && reservation_word <= last_word)
      reservation_valid = 1'b0;
  endfunction

  // CMO requests do not change golden byte values. Invalidation only drops
  // knowledge of bytes that may have lived solely in the cache.
  function void apply_request(hpdcache_cri_req_item req);
    longint unsigned byte_addr;

    if (is_cmo(req.op)) begin
      apply_cmo(req);
      return;
    end
    if (req.op inside {
          HPDCACHE_REQ_AMO_SWAP,
          HPDCACHE_REQ_AMO_ADD,
          HPDCACHE_REQ_AMO_AND,
          HPDCACHE_REQ_AMO_OR,
          HPDCACHE_REQ_AMO_XOR,
          HPDCACHE_REQ_AMO_MAX,
          HPDCACHE_REQ_AMO_MAXU,
          HPDCACHE_REQ_AMO_MIN,
          HPDCACHE_REQ_AMO_MINU
        }) begin
      clear_reservation_if_range_hit(
        longint'(req.addr), 1 << req.size
      );
      return;
    end
    if (req.op != HPDCACHE_REQ_STORE)
      return;
    // The RTL invalidates an LR reservation when any byte in the STORE's
    // address/size range overlaps the reserved word, independent of the write
    // byte enables.
    clear_reservation_if_range_hit(
      longint'(req.addr), 1 << req.size
    );
    for (int unsigned i = 0; i < REQ_BYTES; i++) begin
      if (!req.be[0][i])
        continue;
      byte_addr = (longint'(req.addr) / REQ_BYTES) * REQ_BYTES + i;
      write_byte(byte_addr, req.data[0][i*8 +: 8]);
    end
  endfunction

  // Invalidate only the reference bytes whose cache copy may have been
  // discarded.  The byte values remain untouched; a later memory response
  // re-learns them.  This keeps CMO handling at the golden-memory boundary
  // without modelling cache tags, states, or dirty lines.
  function void apply_cmo(hpdcache_cri_req_item req);
    longint unsigned line_base;
    longint unsigned word_base;

    if (req.op == HPDCACHE_REQ_CMO_INVAL_ALL) begin
      foreach (memory_table[word_base])
        memory_table[word_base].valid = '0;
      return;
    end
    if (req.op != HPDCACHE_REQ_CMO_INVAL_NLINE)
      return;

    line_base = (longint'(req.addr) / CACHELINE_BYTES) * CACHELINE_BYTES;
    foreach (memory_table[word_base]) begin
      if (word_base * MEM_BYTES >= line_base &&
          word_base * MEM_BYTES < line_base + CACHELINE_BYTES)
        memory_table[word_base].valid = '0;
    end
  endfunction

  function bit expect_sc_cmi(hpdcache_cri_req_item req);
    bit should_forward;

    should_forward = reservation_valid &&
                     reservation_word == longint'(req.addr) / 8;
    reservation_valid = 1'b0;
    return should_forward;
  endfunction

  // A completed CMI atomic transaction contains the serialized operation,
  // operand, byte enables, and old value needed to advance golden memory.
  function void apply_atomic_transaction(hpdcache_cmi_atomic_item t);
    logic [63:0] old_operand;
    logic [63:0] request_operand;
    logic [63:0] new_operand;
    logic signed [63:0] old_signed;
    logic signed [63:0] request_signed;
    longint unsigned word_base;
    longint unsigned word_key;
    int unsigned byte_count;
    int unsigned first_byte;

    if (t.err)
      return;

    word_key = longint'(t.addr) / MEM_BYTES;
    word_base = word_key * MEM_BYTES;
    if (t.atop == MEM_ATOMIC_STEX) begin
      if (!t.write_response_valid)
        `uvm_error("HPDCACHE_CHK_REFERENCE",
                   "completed STEX has no write response")
      if (t.exclusive_success) begin
        for (int unsigned i = 0; i < MEM_BYTES; i++) begin
          if (t.request_strb[i])
            write_byte(word_base + i, t.request_data[i*8 +: 8]);
        end
      end
      return;
    end

    if (!t.read_response_valid) begin
      `uvm_error("HPDCACHE_CHK_REFERENCE",
                 "completed atomic transaction has no old-value response")
      return;
    end

    ensure_entry(word_key);
    for (int unsigned i = 0; i < MEM_BYTES; i++) begin
      memory_table[word_key].data[i*8 +: 8] =
        t.response_data[i*8 +: 8];
      memory_table[word_key].valid[i] = 1'b1;
    end

    if (t.atop == MEM_ATOMIC_LDEX) begin
      reservation_valid = 1'b1;
      reservation_word = longint'(t.addr) / 8;
      return;
    end

    old_operand = '0;
    request_operand = '0;
    new_operand = '0;
    byte_count = 0;
    first_byte = MEM_BYTES;
    for (int unsigned i = 0; i < MEM_BYTES; i++) begin
      if (t.request_strb[i]) begin
        if (first_byte == MEM_BYTES)
          first_byte = i;
        byte_count++;
      end
    end
    if (!(byte_count inside {4, 8}) || first_byte + byte_count > MEM_BYTES) begin
      `uvm_error("HPDCACHE_CHK_REFERENCE", $sformatf(
        "illegal atomic byte mask 0x%0h", t.request_strb))
      return;
    end
    for (int unsigned i = 0; i < byte_count; i++) begin
      if (!t.request_strb[first_byte+i]) begin
        `uvm_error("HPDCACHE_CHK_REFERENCE", $sformatf(
          "non-contiguous atomic byte mask 0x%0h", t.request_strb))
        return;
      end
      old_operand[i*8 +: 8] = t.response_data[(first_byte+i)*8 +: 8];
      request_operand[i*8 +: 8] = t.request_data[(first_byte+i)*8 +: 8];
    end

    if (byte_count == 4) begin
      old_signed = {{32{old_operand[31]}}, old_operand[31:0]};
      request_signed = {{32{request_operand[31]}}, request_operand[31:0]};
    end else begin
      old_signed = old_operand;
      request_signed = request_operand;
    end

    case (t.atop)
      MEM_ATOMIC_SWAP: new_operand = request_operand;
      MEM_ATOMIC_ADD:  new_operand = old_operand + request_operand;
      MEM_ATOMIC_CLR:  new_operand = old_operand & ~request_operand;
      MEM_ATOMIC_SET:  new_operand = old_operand | request_operand;
      MEM_ATOMIC_EOR:  new_operand = old_operand ^ request_operand;
      MEM_ATOMIC_SMAX:
        new_operand = old_signed > request_signed ? old_operand : request_operand;
      MEM_ATOMIC_UMAX:
        new_operand = old_operand > request_operand ? old_operand : request_operand;
      MEM_ATOMIC_SMIN:
        new_operand = old_signed < request_signed ? old_operand : request_operand;
      MEM_ATOMIC_UMIN:
        new_operand = old_operand < request_operand ? old_operand : request_operand;
      default: begin
        `uvm_error("HPDCACHE_CHK_REFERENCE", $sformatf(
          "unsupported CMI atomic operation %s", t.atop.name()))
        return;
      end
    endcase

    for (int unsigned i = 0; i < byte_count; i++)
      write_byte(word_base + first_byte + i, new_operand[i*8 +: 8]);
    clear_reservation_if_range_hit(longint'(t.addr), byte_count);
  endfunction

  function bit read_byte(longint unsigned byte_addr, output logic [7:0] data);
    longint unsigned word_key;
    int unsigned mem_byte;

    word_key = byte_addr / MEM_BYTES;
    mem_byte = byte_addr % MEM_BYTES;
    data = '0;
    if (!memory_table.exists(word_key) ||
        !memory_table[word_key].valid[mem_byte])
      return 1'b0;
    data = memory_table[word_key].data[mem_byte*8 +: 8];
    return 1'b1;
  endfunction
endclass
