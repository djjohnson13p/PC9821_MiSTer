// Registered native-bus responder for absent memory regions.
// Acceptance and read response are deliberately separate cycles, matching the
// z486 external-memory contract and avoiding cache allocation via direct MMIO.

`default_nettype none

module pc9821_open_bus (
    input wire clk,
    input wire reset,
    input wire cpu_valid,
    input wire cpu_write,
    input wire cpu_line_read,
    output reg [31:0] cpu_dout,
    output reg [127:0] cpu_line_dout,
    output reg cpu_ready,
    output reg cpu_resp_valid,
    output reg cpu_line_resp_valid
);

  localparam S_IDLE = 2'd0, S_ACCEPT = 2'd1,
             S_RESPONSE = 2'd2, S_HOLD = 2'd3;
  reg [1:0] state;
  reg request_write, request_line;

  always @(posedge clk) begin
    if (reset) begin
      state <= S_IDLE;
      request_write <= 1'b0;
      request_line <= 1'b0;
      cpu_dout <= 32'hFFFF_FFFF;
      cpu_line_dout <= {4{32'hFFFF_FFFF}};
      cpu_ready <= 1'b0;
      cpu_resp_valid <= 1'b0;
      cpu_line_resp_valid <= 1'b0;
    end else begin
      cpu_ready <= 1'b0;
      cpu_resp_valid <= 1'b0;
      cpu_line_resp_valid <= 1'b0;
      case (state)
        S_IDLE: if (cpu_valid) begin
          request_write <= cpu_write;
          request_line <= cpu_line_read;
          state <= S_ACCEPT;
        end
        S_ACCEPT: begin
          cpu_ready <= 1'b1;
          state <= request_write ? S_HOLD : S_RESPONSE;
        end
        S_RESPONSE: begin
          cpu_resp_valid <= !request_line;
          cpu_line_resp_valid <= request_line;
          state <= S_HOLD;
        end
        // One cycle only: the accept (a store) or the response (a read) was
        // delivered in the previous cycle. It must NOT wait for cpu_valid to
        // deassert -- a pipelined CPU need not present one request per valid, and
        // two back-to-back accesses to this route with valid held would deadlock
        // here. See pc9821_memory_subsystem.sv's responder contract.
        S_HOLD: state <= S_IDLE;
        default: state <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
