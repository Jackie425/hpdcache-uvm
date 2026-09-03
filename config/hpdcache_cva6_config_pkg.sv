/*
 * Copyright 2026 OpenHW Group
 *
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Licensed under the Solderpad Hardware License v 2.1 (the "License"); you
 * may not use this file except in compliance with the License, or, at your
 * option, the Apache License version 2.0. You may obtain a copy of the
 * License at https://solderpad.org/licenses/SHL-2.1/.
 */

// SPDX-License-Identifier: Apache-2.0
// Fixed HPDcache configuration used by the CVA6 integration.
package hpdcache_cva6_config_pkg;
  localparam int unsigned PA_WIDTH = 56;
  localparam int unsigned SETS = 256;
  localparam int unsigned WAYS = 8;
  localparam int unsigned WORD_WIDTH = 64;
  localparam int unsigned CL_WORDS = 2;

  localparam int unsigned REQ_WORDS = 1;
  localparam int unsigned REQ_TRANS_ID_WIDTH = 3;
  localparam int unsigned REQ_SRC_ID_WIDTH = 3;

  localparam int unsigned DATA_WAYS_PER_RAM_WORD = 2;
  localparam int unsigned DATA_SETS_PER_RAM = 256;
  localparam bit          DATA_RAM_BYTE_ENABLE = 1'b1;
  localparam int unsigned ACCESS_WORDS = 1;

  localparam int unsigned MSHR_SETS = 1;
  localparam int unsigned MSHR_WAYS = 8;
  localparam int unsigned MSHR_WAYS_PER_RAM_WORD = 8;
  localparam int unsigned MSHR_SETS_PER_RAM = 1;
  localparam bit          MSHR_RAM_BYTE_ENABLE = 1'b1;
  localparam bit          MSHR_USE_REGBANK = 1'b1;
  localparam int unsigned CBUF_ENTRIES = 7;
  localparam bit          REFILL_CORE_RSP_FEEDTHROUGH = 1'b1;
  localparam int          REFILL_FIFO_DEPTH = 4;

  localparam int unsigned WBUF_DIR_ENTRIES = 7;
  localparam int unsigned WBUF_DATA_ENTRIES = 7;
  localparam int unsigned WBUF_WORDS = 1;
  localparam int unsigned WBUF_TIMECNT_WIDTH = 3;
  localparam int unsigned RTAB_ENTRIES = 4;

  // Four CVA6 LSU requesters plus the hardware-prefetch requester.
  localparam int unsigned NREQUESTERS = 5;
  localparam int unsigned MEM_ADDR_WIDTH = 64;
  localparam int unsigned MEM_ID_WIDTH = 4;
  localparam int unsigned MEM_DATA_WIDTH = 64;
  localparam int unsigned FLUSH_ENTRIES = 7;
  localparam int unsigned FLUSH_FIFO_DEPTH = 7;

  localparam bit WT_ENABLE = 1'b0;
  localparam bit WB_ENABLE = 1'b1;
  localparam bit LOW_LATENCY = 1'b1;
  localparam bit ECC_ENABLE = 1'b0;
  localparam bit ECC_SCRUBBER_ENABLE = 1'b0;
endpackage
