`timescale 1ns / 1ps
`include "param.v"

module wb_to_sa #(
    parameter integer BIT_DATA = `BIT_DATA,
    parameter integer DELAY    = 2
)(
    input  wire                 CLK,
    input  wire                 RST,

    // Weight Buffer -> SA
    input  wire [BIT_DATA-1:0]  In_douta,

    // Delayed Weight Data
    output wire [BIT_DATA-1:0]  douta_Out
);

    reg [BIT_DATA*DELAY-1:0] pipe;

    integer i;

    always @(posedge CLK) begin
        if (RST) begin
            pipe <= {BIT_DATA*DELAY{1'b0}};
        end
        else begin

            // Insert new weight data
            pipe[0 +: BIT_DATA] <= In_douta;

            // Shift pipeline
            for (i = 1; i < DELAY; i = i + 1) begin
                pipe[i*BIT_DATA +: BIT_DATA]
                    <= pipe[(i-1)*BIT_DATA +: BIT_DATA];
            end
        end
    end

    assign douta_Out
        = pipe[(DELAY-1)*BIT_DATA +: BIT_DATA];

endmodule