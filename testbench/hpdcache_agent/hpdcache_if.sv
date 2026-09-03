// SPDX-License-Identifier: Apache-2.0

interface hpdcache_if (
  input logic clk_i,
  input logic rst_ni
);

  import hpdcache_pkg::*;
  import hpdcache_cva6_types_pkg::*;

  // Request channel
  logic          req_valid;
  logic          req_ready;
  hpdcache_req_t req;
  logic          req_abort;
  hpdcache_tag_t req_tag;
  hpdcache_pma_t req_pma;

  // Driver-side signals are separate from the observed bus.  This lets a
  // passive instance observe an externally driven requester without its
  // clocking-block outputs becoming additional bus drivers.
  logic          drv_req_valid;
  hpdcache_req_t drv_req;
  logic          drv_req_abort;
  hpdcache_tag_t drv_req_tag;
  hpdcache_pma_t drv_req_pma;

  // Response channel
  logic          rsp_valid;
  hpdcache_rsp_t rsp;


  // --------------------------------------------------------------------------
  // Driver clocking block
  // --------------------------------------------------------------------------
  clocking drv_cb @(posedge clk_i);
    default input #1step output #0;

    input  rst_ni;
    input  req_ready;
    input  rsp_valid;
    input  rsp;

    output drv_req_valid;
    output drv_req;
    output drv_req_abort;
    output drv_req_tag;
    output drv_req_pma;
  endclocking


  // --------------------------------------------------------------------------
  // Monitor clocking block
  // --------------------------------------------------------------------------
  clocking mon_cb @(posedge clk_i);
    default input #1step;

    input rst_ni;

    input req_valid;
    input req_ready;
    input req;
    input req_abort;
    input req_tag;
    input req_pma;

    input rsp_valid;
    input rsp;
  endclocking

endinterface
