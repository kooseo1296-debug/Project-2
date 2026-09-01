`timescale 1ns / 1ps
`include "param.v"

module ctrl_to_wb #(
    parameter integer BIT_ADDR = `ADDR_WSRAM,
    parameter integer BIT_DATA = `BIT_DATA,
    parameter integer DELAY    = 2
)(
    input  wire                 CLK,
    input  wire                 RST,

    // Controller -> Weight Buffer
    input  wire [BIT_ADDR-1:0]  In_addra,
    input  wire [BIT_DATA-1:0]  In_dina,
    input  wire                 In_ena,
    input  wire                 In_wea,

    // Delayed Weight Buffer control
    output wire [BIT_ADDR-1:0]  addra_Out,
    output wire [BIT_DATA-1:0]  dina_Out,
    output wire                 ena_Out,
    output wire                 wea_Out
);

    // {Addr, Data, Enable, Write Enable}
    localparam integer PIPE_WIDTH = BIT_ADDR + BIT_DATA + 2;

    reg [PIPE_WIDTH*DELAY-1:0] pipe;

    integer i;

    always @(posedge CLK) begin
        if (RST) begin
            pipe <= {PIPE_WIDTH*DELAY{1'b0}};
        end
        else begin

            // Insert new transaction
            pipe[0 +: PIPE_WIDTH]
                <= {In_addra, In_dina, In_ena, In_wea};

            // Shift pipeline
            for (i = 1; i < DELAY; i = i + 1) begin
                pipe[i*PIPE_WIDTH +: PIPE_WIDTH]
                    <= pipe[(i-1)*PIPE_WIDTH +: PIPE_WIDTH];
            end
        end
    end

    assign {addra_Out, dina_Out, ena_Out, wea_Out} 
        = pipe[(DELAY-1)*PIPE_WIDTH+: PIPE_WIDTH];
endmodule