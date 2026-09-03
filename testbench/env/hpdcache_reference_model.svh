class hpdcache_reference_model extends uvm_object;
  `uvm_object_utils(hpdcache_reference_model)
  localparam int unsigned MEM_BYTES = MEM_DATA_WIDTH / 8;
  localparam int unsigned REQ_BYTES = REQ_WORDS * (WORD_WIDTH / 8);

  // Sparse shadow memory.  Each table entry represents one downstream memory
  // word.  Keeping data and its byte-valid mask together prevents the model
  // state from becoming two parallel associative arrays that can diverge.
  typedef struct packed {
    logic [MEM_DATA_WIDTH-1:0] data;
    logic [MEM_BYTES-1:0]      valid;
  } memory_entry_t;
  memory_entry_t memory_table[longint unsigned];

  function new(string name = "hpdcache_reference_model");
    super.new(name);
  endfunction

  function void ensure_entry(longint unsigned word_key);
    if (!memory_table.exists(word_key)) begin
      memory_table[word_key] = '0;
    end
  endfunction

  function void reset();
    memory_table.delete();
  endfunction

  // Mirror the downstream model's architectural memory state.  A memory read
  // response materializes one memory word. The return value indicates whether
  // the response was accepted into the golden state.
  function bit apply_memory_response(
    memory_txn#(MEM_ADDR_WIDTH, MEM_DATA_WIDTH, MEM_ID_WIDTH) t
  );
    longint unsigned key;
    if (t.err) return 1'b0;
    key = longint'(t.addr / MEM_BYTES);
    ensure_entry(key);
    // Do not overwrite bytes already modified by an observed core store.
    // This is the same merge rule used by the cv-hpdcache scoreboard when a
    // refill supplies data for a line that has partial known state.
    for (int i = 0; i < MEM_BYTES; i++) begin
      if (!memory_table[key].valid[i]) begin
        memory_table[key].data[i*8 +: 8] = t.data[i*8 +: 8];
        memory_table[key].valid[i] = 1'b1;
      end
    end
    return 1'b1;
  endfunction

  // Only state-changing requests are applied here. Prediction and expected
  // transaction construction belong to hpdcache_predictor.
  function void apply_request(hpdcache_item req);
    longint unsigned byte_addr;
    longint unsigned word_key;
    int unsigned mem_byte;
    if (req.op != HPDCACHE_REQ_STORE) return;
    for (int i = 0; i < REQ_BYTES; i++) begin
      if (!req.be[0][i]) continue;
      byte_addr = longint'(req.addr) + i;
      word_key = byte_addr / MEM_BYTES;
      mem_byte = byte_addr % MEM_BYTES;
      ensure_entry(word_key);
      memory_table[word_key].data[mem_byte*8 +: 8] = req.data[0][i*8 +: 8];
      memory_table[word_key].valid[mem_byte] = 1'b1;
    end
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
