`timescale 1ns / 1ps
`include "param.v"

module im2col3x3_stream #(
    parameter integer BIT_DATA = `BIT_DATA,
    parameter integer BIT_ADDR = `ADDR_ASRAM
)(
    input  wire                         CLK,
    input  wire                         RST,
    input  wire                         Start,
    input  wire [5:0]                   Width,
    input  wire                         Pixel_Valid,
    input  wire [BIT_DATA-1:0]          Pixel_Data,
    output wire                         Pixel_Ready,
    output reg                          Window_Valid,
    output reg  [9*BIT_DATA-1:0]        Window_Data,
    output reg  [BIT_ADDR-1:0]          Window_Addr,
    output reg                          Done
);

reg Active;
reg [5:0] Padded_Row;
reg [5:0] Padded_Col;
reg [BIT_ADDR-1:0] Out_Count;

(* ram_style = "distributed" *) reg [BIT_DATA-1:0] Line_1 [0:33];
(* ram_style = "distributed" *) reg [BIT_DATA-1:0] Line_2 [0:33];

reg [BIT_DATA-1:0] Top_0, Top_1;
reg [BIT_DATA-1:0] Mid_0, Mid_1;
reg [BIT_DATA-1:0] Bot_0, Bot_1;

wire Interior;
wire Step;
wire [BIT_DATA-1:0] Sample;
wire [BIT_DATA-1:0] Top_Sample;
wire [BIT_DATA-1:0] Mid_Sample;
wire [6:0] Padded_Last;

assign Interior = Active &&
                  (Padded_Row >= 1) && (Padded_Row <= Width) &&
                  (Padded_Col >= 1) && (Padded_Col <= Width);
assign Pixel_Ready = Interior;
assign Step = Active && (!Interior || Pixel_Valid);
assign Sample = Interior ? Pixel_Data : {BIT_DATA{1'b0}};
assign Top_Sample = Line_2[Padded_Col];
assign Mid_Sample = Line_1[Padded_Col];
assign Padded_Last = {1'b0, Width} + 7'd1;

always @(posedge CLK) begin
    if (RST) begin
        Active <= 1'b0;
        Padded_Row <= 6'd0;
        Padded_Col <= 6'd0;
        Out_Count <= {BIT_ADDR{1'b0}};
        Top_0 <= {BIT_DATA{1'b0}};
        Top_1 <= {BIT_DATA{1'b0}};
        Mid_0 <= {BIT_DATA{1'b0}};
        Mid_1 <= {BIT_DATA{1'b0}};
        Bot_0 <= {BIT_DATA{1'b0}};
        Bot_1 <= {BIT_DATA{1'b0}};
        Window_Valid <= 1'b0;
        Window_Data <= {(9*BIT_DATA){1'b0}};
        Window_Addr <= {BIT_ADDR{1'b0}};
        Done <= 1'b0;
    end
    else begin
        Window_Valid <= 1'b0;
        Done <= 1'b0;

        if (Start) begin
            Active <= 1'b1;
            Padded_Row <= 6'd0;
            Padded_Col <= 6'd0;
            Out_Count <= {BIT_ADDR{1'b0}};
            Top_0 <= {BIT_DATA{1'b0}};
            Top_1 <= {BIT_DATA{1'b0}};
            Mid_0 <= {BIT_DATA{1'b0}};
            Mid_1 <= {BIT_DATA{1'b0}};
            Bot_0 <= {BIT_DATA{1'b0}};
            Bot_1 <= {BIT_DATA{1'b0}};
        end
        else if (Step) begin
            Line_2[Padded_Col] <= Line_1[Padded_Col];
            Line_1[Padded_Col] <= Sample;

            if (Padded_Col == 0) begin
                Top_0 <= {BIT_DATA{1'b0}};
                Top_1 <= Top_Sample;
                Mid_0 <= {BIT_DATA{1'b0}};
                Mid_1 <= Mid_Sample;
                Bot_0 <= {BIT_DATA{1'b0}};
                Bot_1 <= Sample;
            end
            else begin
                Top_0 <= Top_1;
                Top_1 <= Top_Sample;
                Mid_0 <= Mid_1;
                Mid_1 <= Mid_Sample;
                Bot_0 <= Bot_1;
                Bot_1 <= Sample;
            end

            if ((Padded_Row >= 2) && (Padded_Col >= 2)) begin
                Window_Valid <= 1'b1;
                Window_Addr <= Out_Count;
                Out_Count <= Out_Count + 1'b1;

                Window_Data[0*BIT_DATA +: BIT_DATA] <= Top_0;
                Window_Data[1*BIT_DATA +: BIT_DATA] <= Top_1;
                Window_Data[2*BIT_DATA +: BIT_DATA] <= Top_Sample;
                Window_Data[3*BIT_DATA +: BIT_DATA] <= Mid_0;
                Window_Data[4*BIT_DATA +: BIT_DATA] <= Mid_1;
                Window_Data[5*BIT_DATA +: BIT_DATA] <= Mid_Sample;
                Window_Data[6*BIT_DATA +: BIT_DATA] <= Bot_0;
                Window_Data[7*BIT_DATA +: BIT_DATA] <= Bot_1;
                Window_Data[8*BIT_DATA +: BIT_DATA] <= Sample;
            end

            if (({1'b0,Padded_Row} == Padded_Last) &&
                ({1'b0,Padded_Col} == Padded_Last)) begin
                Active <= 1'b0;
                Done <= 1'b1;
            end
            else if ({1'b0,Padded_Col} == Padded_Last) begin
                Padded_Col <= 6'd0;
                Padded_Row <= Padded_Row + 1'b1;
            end
            else begin
                Padded_Col <= Padded_Col + 1'b1;
            end
        end
    end
end

endmodule
