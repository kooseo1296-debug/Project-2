`timescale 1ns / 1ps
`include "param.v"

module sa_to_pb #(
    parameter integer BIT_ADDR = `ADDR_PSRAM,
    parameter integer BIT_DATA = `BIT_PSUM,
    parameter integer BIT_MSB  = 5,
    parameter integer DELAY    = 2
)(
    input  wire                    CLK,
    input  wire                    RST,

    input  wire [BIT_ADDR-1:0]     In_Addr_P,
    input  wire                    In_Valid_P,
    input  wire [BIT_DATA-1:0]     In_Psum,
    input  wire                    In_En_ReLU,

    output wire [BIT_ADDR-1:0]     Addr_P_Out,
    output wire                    Valid_P_Out,
    output wire [BIT_DATA-1:0]     Psum_Out,
    output wire                    FinishFlag_Out,

    output wire [BIT_MSB-1:0]      Max_MSB_Out,
    output wire                    Max_Valid_Out
);

    reg Prev_Valid_P;
    reg Prev_En_ReLU;
    reg [BIT_MSB-1:0] Max_MSB_Reg;

    wire FinishFlag;
    wire Max_Valid;
    wire [BIT_DATA-1:0] Psum;
    wire [BIT_MSB-1:0] Current_MSB;

    localparam integer PIPE_WIDTH = BIT_ADDR + 1 + BIT_DATA + 1 + BIT_MSB + 1;
    reg [PIPE_WIDTH*DELAY-1:0] pipe;

    integer i;

    function [BIT_MSB-1:0] Find_MSB;
        input [BIT_DATA-1:0] Data;
        integer k;
        begin
            Find_MSB = {BIT_MSB{1'b0}};
            for (k=0; k<BIT_DATA-1; k=k+1)
                if (Data[k]) Find_MSB = k;
        end
    endfunction

    assign FinishFlag = Prev_Valid_P & ~In_Valid_P;
    assign Max_Valid = Prev_En_ReLU & ~In_En_ReLU;

    assign Psum = (In_En_ReLU && In_Psum[BIT_DATA-1]) ? {BIT_DATA{1'b0}} : In_Psum;
    assign Current_MSB = Find_MSB(Psum);

    always @(posedge CLK) begin
        if (RST) begin
            Prev_Valid_P <= 1'b0;
            Prev_En_ReLU <= 1'b0;
            Max_MSB_Reg <= {BIT_MSB{1'b0}};
            pipe <= {PIPE_WIDTH*DELAY{1'b0}};
        end
        else begin
            Prev_Valid_P <= In_Valid_P;
            Prev_En_ReLU <= In_En_ReLU;

            if (In_En_ReLU && (Current_MSB > Max_MSB_Reg))
                Max_MSB_Reg <= Current_MSB;

            if (Max_Valid) Max_MSB_Reg <= {BIT_MSB{1'b0}};

            pipe[0 +: PIPE_WIDTH] <= {In_Addr_P, In_Valid_P, Psum, FinishFlag, Max_MSB_Reg, Max_Valid};

            for (i=1; i<DELAY; i=i+1)
                pipe[i*PIPE_WIDTH +: PIPE_WIDTH] <= pipe[(i-1)*PIPE_WIDTH +: PIPE_WIDTH];
        end
    end

    assign {Addr_P_Out, Valid_P_Out, Psum_Out, FinishFlag_Out, Max_MSB_Out, Max_Valid_Out}
        = pipe[(DELAY-1)*PIPE_WIDTH +: PIPE_WIDTH];

endmodule