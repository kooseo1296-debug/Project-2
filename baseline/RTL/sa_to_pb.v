`timescale 1ns / 1ps
`include "param.v"

module sa_to_pb #(
    parameter integer BIT_ADDR = `ADDR_PSRAM,
    parameter integer BIT_DATA = `BIT_PSUM,
    parameter integer DELAY    = 2
)(
    input  wire                 CLK,
    input  wire                 RST,

    // SA -> Product Buffer
    input  wire [BIT_ADDR-1:0]  In_Addr_P,
    input  wire                 In_Valid_P,
    input  wire [BIT_DATA-1:0]  In_Psum,

    // Delayed outputs
    output wire [BIT_ADDR-1:0]  Addr_P_Out,
    output wire                 Valid_P_Out,
    output wire [BIT_DATA-1:0]  Psum_Out,

    // One-cycle pulse when Valid stream finishes
    output wire                 FinishFlag_Out
);

    // {Addr, Valid, Psum, FinishFlag}
    localparam integer PIPE_WIDTH =
        BIT_ADDR + 1 + BIT_DATA + 1;

    reg [PIPE_WIDTH*DELAY-1:0] pipe;

    reg Prev_Valid_P;

    wire FinishFlag_In;

    integer i;

    assign FinishFlag_In = Prev_Valid_P & ~In_Valid_P;

    always @(posedge CLK) begin
        if (RST) begin
            Prev_Valid_P <= 1'b0;
            pipe         <= {PIPE_WIDTH*DELAY{1'b0}};
        end
        else begin

            // Save current valid for falling-edge detection
            Prev_Valid_P <= In_Valid_P;

            // Insert new transaction
            pipe[0 +: PIPE_WIDTH]
                <= {
                    In_Addr_P,
                    In_Valid_P,
                    In_Psum,
                    FinishFlag_In
                };

            // Shift pipeline
            for (i = 1; i < DELAY; i = i + 1) begin
                pipe[i*PIPE_WIDTH +: PIPE_WIDTH]
                    <= pipe[(i-1)*PIPE_WIDTH +: PIPE_WIDTH];
            end
        end
    end

    assign {
        Addr_P_Out,
        Valid_P_Out,
        Psum_Out,
        FinishFlag_Out
    } =
        pipe[
            (DELAY-1)*PIPE_WIDTH
            +: PIPE_WIDTH
        ];

endmodule