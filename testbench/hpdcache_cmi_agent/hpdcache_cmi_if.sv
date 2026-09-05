interface hpdcache_cmi_if (
  input logic clk_i,
  input logic rst_ni
);
  import hpdcache_pkg::*;
  import hpdcache_cva6_types_pkg::*;

  logic                  mem_req_read_ready;
  logic                  mem_req_read_valid;
  hpdcache_mem_req_t     mem_req_read;
  logic                  mem_rsp_read_ready;
  logic                  mem_rsp_read_valid;
  hpdcache_mem_resp_r_t  mem_rsp_read;
  logic                  mem_req_write_ready;
  logic                  mem_req_write_valid;
  hpdcache_mem_req_t     mem_req_write;
  logic                  mem_req_write_data_ready;
  logic                  mem_req_write_data_valid;
  hpdcache_mem_req_w_t   mem_req_write_data;
  logic                  mem_rsp_write_ready;
  logic                  mem_rsp_write_valid;
  hpdcache_mem_resp_w_t  mem_rsp_write;

  clocking mon_cb @(posedge clk_i);
    default input #1step;

    input rst_ni;
    input mem_req_read_ready;
    input mem_req_read_valid;
    input mem_req_read;
    input mem_rsp_read_ready;
    input mem_rsp_read_valid;
    input mem_rsp_read;
    input mem_req_write_ready;
    input mem_req_write_valid;
    input mem_req_write;
    input mem_req_write_data_ready;
    input mem_req_write_data_valid;
    input mem_req_write_data;
    input mem_rsp_write_ready;
    input mem_rsp_write_valid;
    input mem_rsp_write;
  endclocking
endinterface
