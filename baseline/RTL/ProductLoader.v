`timescale 1ns / 1ps
`include "param.v"

module ProductLoader #(
    parameter integer BIT_DATA = `BIT_PSUM,
    parameter integer DELAY    = 2,
    parameter integer COLNUM   = 0
)(
    input  wire                 CLK,
    input  wire                 RST,

    input  wire                 En_Tile_In,
    input  wire [BIT_DATA-1:0]  Data_In,

    output wire [BIT_DATA-1:0]  Data_Out
);

    localparam integer PIPE_DEPTH = DELAY + COLNUM;

    reg En_Tile;

    reg [BIT_DATA*PIPE_DEPTH-1:0] pipe;

    integer i;

    always @(posedge CLK) begin
        if (RST) begin
            En_Tile <= 1'b0;
            pipe <= {BIT_DATA*PIPE_DEPTH{1'b0}};
        end
        else begin
            En_Tile <= En_Tile_In;
            pipe[0 +: BIT_DATA] <= En_Tile? Data_In : {BIT_DATA{1'b0}};
            for (i = 1;i < PIPE_DEPTH;i = i + 1) begin
                pipe[i*BIT_DATA+: BIT_DATA] <= pipe[(i-1)*BIT_DATA+: BIT_DATA];
            end
        end
    end

    assign Data_Out =pipe[(PIPE_DEPTH-1)*BIT_DATA+: BIT_DATA];
endmodule