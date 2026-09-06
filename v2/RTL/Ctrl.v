`timescale 1ns / 1ps
`include "param.v"

module Ctrl #(
    parameter integer BIT_OFFSET   = 2,
    parameter integer BIT_INSTR    = 32,
    parameter integer BIT_COLNUM   = 8,
    parameter integer BIT_CMD_ADDR = 16,
    parameter integer BIT_SHIFT    = 5
)(
    // AXI -> Ctrl
    input  wire                         CLK,
    input  wire                         RST,
    input  wire                         In_Valid,
    input  wire [BIT_OFFSET-1:0]        In_Offset,
    input  wire [BIT_INSTR-1:0]         In_Instruction,
    input  wire                         In_Rcode_Read,

    // Ctrl -> AXI
    output wire [BIT_INSTR-1:0]         Rcode_Out,

    // Ctrl -> WB
    output reg  [`ADDR_WSRAM-1:0]       WB_addra_Out,
    output reg  [`PE_COL*`BIT_DATA-1:0] WB_dina_Out,
    output reg  [`PE_COL-1:0]           WB_ena_Out,
    output reg  [`PE_COL-1:0]           WB_wea_Out,

    // Ctrl -> AB
    output reg  [`ADDR_ASRAM-1:0]       AB_addra_Out,
    output reg  [`PE_ROW*`BIT_DATA-1:0] AB_dina_Out,
    output reg  [`PE_ROW-1:0]           AB_ena_Out,
    output reg  [`PE_ROW-1:0]           AB_wea_Out,

    // Ctrl -> SA / ctrl_to_sa
    output reg  [`PE_COL-1:0]           SA_En_W_Out,
    output reg  [`BIT_ROW_ID-1:0]       SA_En_ID_Out,
    output reg  [`ADDR_PSRAM-1:0]       SA_Addr_P_Out,
    output reg  [`PE_COL-1:0]           SA_Valid_P_Out,
    output reg                          SA_En_ReLU_Out,
    input  wire                         In_SA_Done_W,
    input  wire [`PE_COL-1:0]           In_SA_Done_I,

    // Ctrl -> ctrl_to_pb / ProductLoader
    output reg  [`PE_COL-1:0]           PB_Valid_Out,
    output reg  [`ADDR_PSRAM-1:0]       PB_Addr_Out,
    output reg  [`PE_COL-1:0]           PB_En_Tile_Out,
    output reg                          PB_En_Maxpool_Out,
    output reg                          PB_En_Requant_Out,
    output reg                          PB_To_Ctrl_Out,
    output reg  [`PE_COL*`BIT_PSUM-1:0] PB_Bias_Out,

    // ctrl_to_pb -> Ctrl
    input  wire [`PE_COL-1:0]           In_PB_Valid,
    input  wire [`ADDR_PSRAM-1:0]       In_PB_addr,
    input  wire [`BIT_PSUM-1:0]         In_PB_Data,
    input  wire                         In_PB_To_Ctrl,

    // sa_to_pb -> Ctrl
    input  wire [`PE_COL-1:0]           In_FinishFlag,

    // Ctrl -> biggest
    output reg  [7:0]                   Biggest_Count_Out,

    // biggest -> Ctrl
    input  wire                         In_Biggest_Valid,
    input  wire [BIT_SHIFT-1:0]         In_Biggest_Max_Shift
);

localparam [BIT_OFFSET-1:0] OFFSET_RCODE  = 2'd0;
localparam [BIT_OFFSET-1:0] OFFSET_LOAD_W = 2'd1;
localparam [BIT_OFFSET-1:0] OFFSET_LOAD_A = 2'd2;
localparam [BIT_OFFSET-1:0] OFFSET_LOAD_B = 2'd3;

localparam [3:0] ST_IDLE       = 4'd0;
localparam [3:0] ST_WLOAD      = 4'd1;
localparam [3:0] ST_WAIT_W     = 4'd2;
localparam [3:0] ST_MAC        = 4'd3;
localparam [3:0] ST_DRAIN      = 4'd4;
localparam [3:0] ST_WAIT_LAYER = 4'd5;
localparam [3:0] ST_GAP        = 4'd6;
localparam [3:0] ST_GAP_ZERO   = 4'd7;
localparam [3:0] ST_FC1_FETCH  = 4'd8;
localparam [3:0] ST_FC1_ZERO   = 4'd9;
localparam [3:0] ST_FINAL_FETCH= 4'd10;

localparam [`ADDR_PSRAM-1:0] PB_REGION_A = 0;
localparam [`ADDR_PSRAM-1:0] PB_REGION_B = 2048;

// Weight layout: K-tile major, OC-tile minor, 9 addresses per tile.
localparam [`ADDR_WSRAM-1:0] WBASE_CONV1 = 0;
localparam [`ADDR_WSRAM-1:0] WBASE_CONV2 = 54;
localparam [`ADDR_WSRAM-1:0] WBASE_CONV3 = 630;
localparam [`ADDR_WSRAM-1:0] WBASE_CONV4 = 1782;
localparam [`ADDR_WSRAM-1:0] WBASE_CONV5 = 4086;
localparam [`ADDR_WSRAM-1:0] WBASE_CONV6 = 7542;
localparam [`ADDR_WSRAM-1:0] WBASE_FC1   = 12726;
localparam [`ADDR_WSRAM-1:0] WBASE_FC2   = 13518;

localparam integer FIFO_DEPTH = 128;
localparam integer FIFO_LIMIT = 96;
localparam integer BIT_FIFO_PTR = 7;
localparam integer BIT_FIFO_LEVEL = 8;
localparam integer BIT_OC_ID = 8;
localparam integer BIT_K_ID = 8;
localparam integer BIT_S_CNT = 11;
localparam integer BIT_COL_ID = 4;

integer i;

// -----------------------------------------------------------------------------
// Layer configuration
// Layer 0..5: Conv1..Conv6, 6: FC1, 7: FC2
// -----------------------------------------------------------------------------
function [10:0] Layer_S;
    input [2:0] L;
    begin
        case (L)
            3'd0: Layer_S = 11'd1024;
            3'd1: Layer_S = 11'd1024;
            3'd2: Layer_S = 11'd256;
            3'd3: Layer_S = 11'd256;
            3'd4: Layer_S = 11'd64;
            3'd5: Layer_S = 11'd64;
            default: Layer_S = 11'd1;
        endcase
    end
endfunction

function [7:0] Layer_OC;
    input [2:0] L;
    begin
        case (L)
            3'd0: Layer_OC = 8'd32;
            3'd1: Layer_OC = 8'd32;
            3'd2: Layer_OC = 8'd64;
            3'd3: Layer_OC = 8'd64;
            3'd4: Layer_OC = 8'd96;
            3'd5: Layer_OC = 8'd96;
            3'd6: Layer_OC = 8'd128;
            default: Layer_OC = 8'd10;
        endcase
    end
endfunction

function [7:0] Layer_K_Tiles;
    input [2:0] L;
    begin
        case (L)
            3'd0: Layer_K_Tiles = 8'd3;
            3'd1: Layer_K_Tiles = 8'd32;
            3'd2: Layer_K_Tiles = 8'd32;
            3'd3: Layer_K_Tiles = 8'd64;
            3'd4: Layer_K_Tiles = 8'd64;
            3'd5: Layer_K_Tiles = 8'd96;
            3'd6: Layer_K_Tiles = 8'd11;
            default: Layer_K_Tiles = 8'd15;
        endcase
    end
endfunction

function [5:0] Layer_Width;
    input [2:0] L;
    begin
        case (L)
            3'd0, 3'd1: Layer_Width = 6'd32;
            3'd2, 3'd3: Layer_Width = 6'd16;
            3'd4, 3'd5: Layer_Width = 6'd8;
            default: Layer_Width = 6'd1;
        endcase
    end
endfunction

function Layer_ReLU;
    input [2:0] L;
    begin
        Layer_ReLU = (L != 3'd7);
    end
endfunction

function Layer_Is_FC;
    input [2:0] L;
    begin
        Layer_Is_FC = (L >= 3'd6);
    end
endfunction

function [`ADDR_WSRAM-1:0] Layer_WBase;
    input [2:0] L;
    begin
        case (L)
            3'd0: Layer_WBase = WBASE_CONV1;
            3'd1: Layer_WBase = WBASE_CONV2;
            3'd2: Layer_WBase = WBASE_CONV3;
            3'd3: Layer_WBase = WBASE_CONV4;
            3'd4: Layer_WBase = WBASE_CONV5;
            3'd5: Layer_WBase = WBASE_CONV6;
            3'd6: Layer_WBase = WBASE_FC1;
            default: Layer_WBase = WBASE_FC2;
        endcase
    end
endfunction

function [`ADDR_PSRAM-1:0] Layer_Dest_Base;
    input [2:0] L;
    begin
        if (L[0]) Layer_Dest_Base = PB_REGION_B;
        else Layer_Dest_Base = PB_REGION_A;
    end
endfunction

function [9:0] Bias_Layer_Base;
    input [2:0] L;
    begin
        case (L)
            3'd0: Bias_Layer_Base = 10'd0;
            3'd1: Bias_Layer_Base = 10'd32;
            3'd2: Bias_Layer_Base = 10'd64;
            3'd3: Bias_Layer_Base = 10'd128;
            3'd4: Bias_Layer_Base = 10'd192;
            3'd5: Bias_Layer_Base = 10'd288;
            3'd6: Bias_Layer_Base = 10'd384;
            default: Bias_Layer_Base = 10'd512;
        endcase
    end
endfunction

function Source_Uses_Maxpool;
    input [2:0] Target_Layer;
    begin
        Source_Uses_Maxpool = (Target_Layer == 3'd2) || (Target_Layer == 3'd4);
    end
endfunction

function [`ADDR_PSRAM-1:0] Source_Channel_Base;
    input [2:0] Target_Layer;
    input [7:0] Channel;
    reg [`ADDR_PSRAM-1:0] Tile_Wide;
    begin
        Tile_Wide = Channel >> 4;
        case (Target_Layer)
            3'd1: Source_Channel_Base = PB_REGION_A + (Tile_Wide << 10);
            3'd2: Source_Channel_Base = PB_REGION_B + (Tile_Wide << 10);
            3'd3: Source_Channel_Base = PB_REGION_A + (Tile_Wide << 8);
            3'd4: Source_Channel_Base = PB_REGION_B + (Tile_Wide << 8);
            default: Source_Channel_Base = PB_REGION_A + (Tile_Wide << 6); // Conv5 -> Conv6
        endcase
    end
endfunction

function [`ADDR_PSRAM-1:0] Pool_Source_Offset;
    input [2:0] Target_Layer;
    input [5:0] Out_Row;
    input [5:0] Out_Col;
    input [1:0] Phase;
    reg [`ADDR_PSRAM-1:0] Src_Row;
    reg [`ADDR_PSRAM-1:0] Src_Col;
    begin
        Src_Row = Out_Row;
        Src_Col = Out_Col;
        Src_Row = (Src_Row << 1) + Phase[1];
        Src_Col = (Src_Col << 1) + Phase[0];
        if (Target_Layer == 3'd2)
            Pool_Source_Offset = (Src_Row << 5) + Src_Col; // 32x32 source
        else
            Pool_Source_Offset = (Src_Row << 4) + Src_Col; // 16x16 source
    end
endfunction

function [`ADDR_PSRAM-1:0] Gap_Source_Addr;
    input [7:0] Channel;
    input [6:0] Req;
    reg [`ADDR_PSRAM-1:0] Tile;
    reg [`ADDR_PSRAM-1:0] Out_Row;
    reg [`ADDR_PSRAM-1:0] Out_Col;
    reg [`ADDR_PSRAM-1:0] Src_Row;
    reg [`ADDR_PSRAM-1:0] Src_Col;
    begin
        Tile = Channel >> 4;
        Out_Row = Req >> 4;
        Out_Col = (Req >> 2) & 3;
        Src_Row = (Out_Row << 1) + Req[1];
        Src_Col = (Out_Col << 1) + Req[0];
        Gap_Source_Addr = PB_REGION_B + (Tile << 6) + (Src_Row << 3) + Src_Col;
    end
endfunction

function [5:0] Source_Out_Width;
    input [2:0] Target_Layer;
    begin
        Source_Out_Width = Layer_Width(Target_Layer);
    end
endfunction

// -----------------------------------------------------------------------------
// Command decode
// -----------------------------------------------------------------------------
wire [BIT_CMD_ADDR-1:0] Cmd_Addr;
wire [BIT_COLNUM-1:0] Cmd_Column;
wire [`BIT_DATA-1:0] Cmd_Data;
assign {Cmd_Addr, Cmd_Column, Cmd_Data} = In_Instruction;

wire Bias_Header;
wire [6:0] Bias_Cmd_Layer;
wire [23:0] Bias_Cmd_Number;
wire signed [30:0] Bias_Cmd_Value;
assign Bias_Header = ~In_Instruction[31];
assign Bias_Cmd_Layer = In_Instruction[30:24];
assign Bias_Cmd_Number = In_Instruction[23:0];
assign Bias_Cmd_Value = In_Instruction[30:0];

// -----------------------------------------------------------------------------
// RCODE and final logits
// {BUSY, DONE, Class[3:0], Value[25:0]}
// In_Rcode_Read advances to the next stored class after each accepted 0x00 read.
// -----------------------------------------------------------------------------
reg BUSY;
reg DONE;
reg INFER;
reg [3:0] Result_Index;
reg signed [`BIT_PSUM-1:0] Result_Value;
reg signed [`BIT_PSUM-1:0] Logit_Mem [0:9];
wire [25:0] Result_Value_26;
assign Result_Value_26 = {{(26-`BIT_PSUM){Result_Value[`BIT_PSUM-1]}}, Result_Value};
assign Rcode_Out = {BUSY, DONE, Result_Index, Result_Value_26};

// -----------------------------------------------------------------------------
// Bias storage. 522 immutable base biases are loaded once by PS.
// One bias is read per cycle while the first K tile loads its weights.
// The cumulative dynamic shift is applied before driving ProductLoader.
// -----------------------------------------------------------------------------
(* ram_style = "distributed" *) reg signed [30:0] Bias_Mem [0:521];

reg Bias_Load_Pending;
reg [2:0] Bias_Load_Layer;
reg [23:0] Bias_Load_Number;
reg [5:0] Cum_Shift;

reg Bias_Prep_Active;
reg Bias_Prep_Ready;
reg [4:0] Bias_Prep_Issue;
reg [9:0] Bias_Prep_Base_Index;

reg [9:0] Bias_Addr_Reg;
reg [3:0] Bias_Addr_Col_Reg;
reg Bias_Addr_Valid_Reg;
reg signed [30:0] Bias_Select_Reg;
reg [3:0] Bias_Select_Col_Reg;
reg Bias_Select_Valid_Reg;
wire signed [30:0] Bias_Shifted;
assign Bias_Shifted = $signed(Bias_Select_Reg) >>> Cum_Shift;

// -----------------------------------------------------------------------------
// Main MatMul scheduler state
// -----------------------------------------------------------------------------
reg [3:0] State;
reg [2:0] Layer;
reg [BIT_K_ID-1:0] K_Index;
reg [BIT_OC_ID-1:0] Cnt_OC;
reg [BIT_S_CNT-1:0] Cnt_S;
reg [`BIT_ROW_ID-1:0] Cnt_W_Row;
reg [`ADDR_WSRAM-1:0] WB_Tile_Base;
reg [`ADDR_PSRAM-1:0] PB_Tile_Base;
reg W_Done_Latched;
reg AB_Ready;

wire [10:0] Cur_S;
wire [7:0] Cur_OC;
wire [7:0] Cur_K_Tiles;
wire More_OC;
wire More_K;
wire Final_OC;
wire Final_K;
wire Cur_Is_FC;
wire Cur_ReLU;
assign Cur_S = Layer_S(Layer);
assign Cur_OC = Layer_OC(Layer);
assign Cur_K_Tiles = Layer_K_Tiles(Layer);
assign More_OC = ((Cnt_OC + `PE_COL) < Cur_OC);
assign More_K = ((K_Index + 1'b1) < Cur_K_Tiles);
assign Final_OC = ~More_OC;
assign Final_K = ~More_K;
assign Cur_Is_FC = Layer_Is_FC(Layer);
assign Cur_ReLU = Layer_ReLU(Layer);

reg [`PE_COL-1:0] Active_Col_Mask;
reg [BIT_COL_ID-1:0] Last_Active_Col;
always @(*) begin
    // Model2 has OC multiples of 16 for every layer except FC2 (OC=10).
    // Keeping this model-specific avoids a 16-way runtime compare network.
    if (Layer == 3'd7) begin
        Active_Col_Mask = 16'b0000_0011_1111_1111;
        Last_Active_Col = 4'd9;
    end
    else begin
        Active_Col_Mask = {`PE_COL{1'b1}};
        Last_Active_Col = `PE_COL - 1;
    end
end

// -----------------------------------------------------------------------------
// RGB raw buffer. One channel is buffered while the previous channel computes.
// -----------------------------------------------------------------------------
(* ram_style = "distributed" *) reg [`BIT_DATA-1:0] Raw_Buffer [0:1023];
reg [10:0] Raw_Load_Count;
reg [1:0] Expected_Color;
reg Raw_Ready;

// -----------------------------------------------------------------------------
// One shared im2col engine
// -----------------------------------------------------------------------------
reg Prep_Needed;
reg Prep_Busy;
reg Prep_Is_Raw;
reg [7:0] Prep_Target_K;
reg [10:0] Raw_Read_Index;
reg I2C_Start;
reg [5:0] I2C_Width;
wire I2C_Pixel_Ready;
wire I2C_Window_Valid;
wire [9*`BIT_DATA-1:0] I2C_Window_Data;
wire [`ADDR_ASRAM-1:0] I2C_Window_Addr;
wire I2C_Done;
wire I2C_Pixel_Valid;
wire [`BIT_DATA-1:0] I2C_Pixel_Data;

// PB-return FIFO decouples ctrl_to_pb latency from padding bubbles.
(* ram_style = "distributed" *) reg [`BIT_DATA-1:0] Source_FIFO [0:FIFO_DEPTH-1];
reg [BIT_FIFO_PTR-1:0] FIFO_WPtr;
reg [BIT_FIFO_PTR-1:0] FIFO_RPtr;
reg [BIT_FIFO_LEVEL-1:0] FIFO_Level;
wire FIFO_Push;
wire FIFO_Pop;
assign FIFO_Push = Prep_Busy && !Prep_Is_Raw && In_PB_To_Ctrl && (|In_PB_Valid);
assign FIFO_Pop = Prep_Busy && !Prep_Is_Raw && I2C_Pixel_Ready && (FIFO_Level != 0);
assign I2C_Pixel_Valid = Prep_Busy && (Prep_Is_Raw ? (Raw_Read_Index < 1024) : (FIFO_Level != 0));
assign I2C_Pixel_Data = Prep_Is_Raw ? Raw_Buffer[Raw_Read_Index] : Source_FIFO[FIFO_RPtr];

im2col3x3_stream u_im2col3x3_stream (
    .CLK(CLK),
    .RST(RST),
    .Start(I2C_Start),
    .Width(I2C_Width),
    .Pixel_Valid(I2C_Pixel_Valid),
    .Pixel_Data(I2C_Pixel_Data),
    .Pixel_Ready(I2C_Pixel_Ready),
    .Window_Valid(I2C_Window_Valid),
    .Window_Data(I2C_Window_Data),
    .Window_Addr(I2C_Window_Addr),
    .Done(I2C_Done)
);

// Source-PB request generator used by Conv1->2 through Conv5->6.
reg [11:0] Src_Request_Count;
reg [5:0] Src_Out_Row;
reg [5:0] Src_Out_Col;
reg [1:0] Src_Pool_Phase;
reg Src_Request_Done;
wire Src_Maxpool;
wire [5:0] Src_Out_Width;
wire [`ADDR_PSRAM-1:0] Src_Channel_Base;
wire [`PE_COL-1:0] Src_Onehot_Bank;
wire [`ADDR_PSRAM-1:0] Src_Pool_Offset;
assign Src_Maxpool = Source_Uses_Maxpool(Layer);
assign Src_Out_Width = Source_Out_Width(Layer);
assign Src_Channel_Base = Source_Channel_Base(Layer, Prep_Target_K);
assign Src_Onehot_Bank = ({{(`PE_COL-1){1'b0}},1'b1} << Prep_Target_K[3:0]);
assign Src_Pool_Offset = Pool_Source_Offset(Layer, Src_Out_Row, Src_Out_Col, Src_Pool_Phase);

// -----------------------------------------------------------------------------
// GAP and FC packing/fetch counters
// -----------------------------------------------------------------------------
reg [7:0] Gap_Req_Channel;
reg [6:0] Gap_Req_In_Channel;
reg [7:0] Gap_Ret_Channel;
reg [4:0] Gap_Ret_Count;
reg [10:0] Gap_Sum;
reg [3:0] Pack_Bank;
reg [4:0] Pack_Addr;
wire [10:0] Gap_Sum_Next;
wire [`BIT_DATA-1:0] Gap_Value;
assign Gap_Sum_Next = Gap_Sum + {{(11-`BIT_DATA){1'b0}}, In_PB_Data[`BIT_DATA-1:0]};
assign Gap_Value = (Gap_Sum_Next >> 4) + Gap_Sum_Next[3];

reg [7:0] FC1_Req_Index;
reg [7:0] FC1_Ret_Index;
reg [3:0] Final_Req_Index;
reg [3:0] Final_Ret_Index;

// -----------------------------------------------------------------------------
// Helper wires for PB addresses in MAC mode
// -----------------------------------------------------------------------------
wire [`ADDR_ASRAM-1:0] MAC_AB_Addr;
wire [`ADDR_PSRAM-1:0] MAC_PB_Addr;
assign MAC_AB_Addr = Cur_Is_FC ? K_Index : Cnt_S;
assign MAC_PB_Addr = PB_Tile_Base + Cnt_S;

// -----------------------------------------------------------------------------
// Sequential controller
// -----------------------------------------------------------------------------
always @(posedge CLK) begin
    if (RST) begin
        WB_addra_Out <= 0;
        WB_dina_Out <= 0;
        WB_ena_Out <= 0;
        WB_wea_Out <= 0;
        AB_addra_Out <= 0;
        AB_dina_Out <= 0;
        AB_ena_Out <= 0;
        AB_wea_Out <= 0;
        SA_En_W_Out <= 0;
        SA_En_ID_Out <= 0;
        SA_Addr_P_Out <= 0;
        SA_Valid_P_Out <= 0;
        SA_En_ReLU_Out <= 1'b0;
        PB_Valid_Out <= 0;
        PB_Addr_Out <= 0;
        PB_En_Tile_Out <= 0;
        PB_En_Maxpool_Out <= 1'b0;
        PB_En_Requant_Out <= 1'b0;
        PB_To_Ctrl_Out <= 1'b0;
        PB_Bias_Out <= 0;
        Biggest_Count_Out <= 0;

        BUSY <= 1'b0;
        DONE <= 1'b0;
        INFER <= 1'b0;
        Result_Index <= 0;
        Result_Value <= 0;

        Bias_Load_Pending <= 1'b0;
        Bias_Load_Layer <= 0;
        Bias_Load_Number <= 0;
        Cum_Shift <= 0;
        Bias_Prep_Active <= 1'b0;
        Bias_Prep_Ready <= 1'b0;
        Bias_Prep_Issue <= 0;
        Bias_Prep_Base_Index <= 0;
        Bias_Addr_Reg <= 0;
        Bias_Addr_Col_Reg <= 0;
        Bias_Addr_Valid_Reg <= 1'b0;
        Bias_Select_Reg <= 0;
        Bias_Select_Col_Reg <= 0;
        Bias_Select_Valid_Reg <= 1'b0;

        State <= ST_IDLE;
        Layer <= 0;
        K_Index <= 0;
        Cnt_OC <= 0;
        Cnt_S <= 0;
        Cnt_W_Row <= 0;
        WB_Tile_Base <= WBASE_CONV1;
        PB_Tile_Base <= PB_REGION_A;
        W_Done_Latched <= 1'b0;
        AB_Ready <= 1'b0;

        Raw_Load_Count <= 0;
        Expected_Color <= 0;
        Raw_Ready <= 1'b0;

        Prep_Needed <= 1'b0;
        Prep_Busy <= 1'b0;
        Prep_Is_Raw <= 1'b0;
        Prep_Target_K <= 0;
        Raw_Read_Index <= 0;
        I2C_Start <= 1'b0;
        I2C_Width <= 6'd32;

        FIFO_WPtr <= 0;
        FIFO_RPtr <= 0;
        FIFO_Level <= 0;
        Src_Request_Count <= 0;
        Src_Out_Row <= 0;
        Src_Out_Col <= 0;
        Src_Pool_Phase <= 0;
        Src_Request_Done <= 1'b0;

        Gap_Req_Channel <= 0;
        Gap_Req_In_Channel <= 0;
        Gap_Ret_Channel <= 0;
        Gap_Ret_Count <= 0;
        Gap_Sum <= 0;
        Pack_Bank <= 0;
        Pack_Addr <= 0;
        FC1_Req_Index <= 0;
        FC1_Ret_Index <= 0;
        Final_Req_Index <= 0;
        Final_Ret_Index <= 0;
    end
    else begin
        // Pulse outputs default low.
        WB_ena_Out <= 0;
        WB_wea_Out <= 0;
        AB_ena_Out <= 0;
        AB_wea_Out <= 0;
        SA_En_W_Out <= 0;
        SA_Valid_P_Out <= 0;
        SA_En_ReLU_Out <= 1'b0;
        PB_Valid_Out <= 0;
        PB_En_Tile_Out <= 0;
        PB_En_Maxpool_Out <= 1'b0;
        PB_En_Requant_Out <= 1'b0;
        PB_To_Ctrl_Out <= 1'b0;
        Biggest_Count_Out <= 0;
        I2C_Start <= 1'b0;
        Bias_Addr_Valid_Reg <= 1'b0;
        Bias_Select_Valid_Reg <= 1'b0;

        // -----------------------------------------------------------------
        // RCODE read sequencing after all 10 logits are stored.
        // -----------------------------------------------------------------
        if (DONE && In_Rcode_Read) begin
            if (Result_Index == 4'd9) begin
                Result_Index <= 4'd0;
                Result_Value <= Logit_Mem[0];
            end
            else begin
                Result_Index <= Result_Index + 1'b1;
                case (Result_Index)
                    4'd0: Result_Value <= Logit_Mem[1];
                    4'd1: Result_Value <= Logit_Mem[2];
                    4'd2: Result_Value <= Logit_Mem[3];
                    4'd3: Result_Value <= Logit_Mem[4];
                    4'd4: Result_Value <= Logit_Mem[5];
                    4'd5: Result_Value <= Logit_Mem[6];
                    4'd6: Result_Value <= Logit_Mem[7];
                    4'd7: Result_Value <= Logit_Mem[8];
                    default: Result_Value <= Logit_Mem[9];
                endcase
            end
        end

        // -----------------------------------------------------------------
        // Biggest result: ctrl_to_pb gets its own copy directly; Ctrl only
        // accumulates the shift for all later layer biases.
        // -----------------------------------------------------------------
        if (In_Biggest_Valid) begin
            if ((Cum_Shift + In_Biggest_Max_Shift) > 31)
                Cum_Shift <= 6'd31;
            else
                Cum_Shift <= Cum_Shift + In_Biggest_Max_Shift;
        end

        // -----------------------------------------------------------------
        // Bias preparation pipeline. Only K tile 0 uses bias.
        // A: register flat-memory address, B: memory read, C: >>> Cum_Shift.
        // -----------------------------------------------------------------
        if (Bias_Prep_Active) begin
            Bias_Addr_Reg <= Bias_Prep_Base_Index + Bias_Prep_Issue;
            Bias_Addr_Col_Reg <= Bias_Prep_Issue[3:0];
            Bias_Addr_Valid_Reg <= 1'b1;

            if (Bias_Prep_Issue[3:0] == Last_Active_Col) Bias_Prep_Active <= 1'b0;
            else Bias_Prep_Issue <= Bias_Prep_Issue + 1'b1;
        end

        if (Bias_Addr_Valid_Reg) begin
            Bias_Select_Reg <= Bias_Mem[Bias_Addr_Reg];
            Bias_Select_Col_Reg <= Bias_Addr_Col_Reg;
            Bias_Select_Valid_Reg <= 1'b1;
        end

        if (Bias_Select_Valid_Reg) begin
            case (Bias_Select_Col_Reg)
                4'd0: PB_Bias_Out[0*`BIT_PSUM +: `BIT_PSUM] <= Bias_Shifted[`BIT_PSUM-1:0];
                4'd1: PB_Bias_Out[1*`BIT_PSUM +: `BIT_PSUM] <= Bias_Shifted[`BIT_PSUM-1:0];
                4'd2: PB_Bias_Out[2*`BIT_PSUM +: `BIT_PSUM] <= Bias_Shifted[`BIT_PSUM-1:0];
                4'd3: PB_Bias_Out[3*`BIT_PSUM +: `BIT_PSUM] <= Bias_Shifted[`BIT_PSUM-1:0];
                4'd4: PB_Bias_Out[4*`BIT_PSUM +: `BIT_PSUM] <= Bias_Shifted[`BIT_PSUM-1:0];
                4'd5: PB_Bias_Out[5*`BIT_PSUM +: `BIT_PSUM] <= Bias_Shifted[`BIT_PSUM-1:0];
                4'd6: PB_Bias_Out[6*`BIT_PSUM +: `BIT_PSUM] <= Bias_Shifted[`BIT_PSUM-1:0];
                4'd7: PB_Bias_Out[7*`BIT_PSUM +: `BIT_PSUM] <= Bias_Shifted[`BIT_PSUM-1:0];
                4'd8: PB_Bias_Out[8*`BIT_PSUM +: `BIT_PSUM] <= Bias_Shifted[`BIT_PSUM-1:0];
                4'd9: PB_Bias_Out[9*`BIT_PSUM +: `BIT_PSUM] <= Bias_Shifted[`BIT_PSUM-1:0];
                4'd10: PB_Bias_Out[10*`BIT_PSUM +: `BIT_PSUM] <= Bias_Shifted[`BIT_PSUM-1:0];
                4'd11: PB_Bias_Out[11*`BIT_PSUM +: `BIT_PSUM] <= Bias_Shifted[`BIT_PSUM-1:0];
                4'd12: PB_Bias_Out[12*`BIT_PSUM +: `BIT_PSUM] <= Bias_Shifted[`BIT_PSUM-1:0];
                4'd13: PB_Bias_Out[13*`BIT_PSUM +: `BIT_PSUM] <= Bias_Shifted[`BIT_PSUM-1:0];
                4'd14: PB_Bias_Out[14*`BIT_PSUM +: `BIT_PSUM] <= Bias_Shifted[`BIT_PSUM-1:0];
                default: PB_Bias_Out[15*`BIT_PSUM +: `BIT_PSUM] <= Bias_Shifted[`BIT_PSUM-1:0];
            endcase
            if (Bias_Select_Col_Reg == Last_Active_Col) Bias_Prep_Ready <= 1'b1;
        end

        // -----------------------------------------------------------------
        // External model preload commands are accepted only outside inference.
        // -----------------------------------------------------------------
        if (!INFER && In_Valid && (In_Offset == OFFSET_LOAD_W)) begin
            if (Cmd_Column < `PE_COL) begin
                WB_addra_Out <= Cmd_Addr[`ADDR_WSRAM-1:0];
                WB_dina_Out <= {`PE_COL{Cmd_Data}};
                WB_ena_Out <= ({{(`PE_COL-1){1'b0}},1'b1} << Cmd_Column);
                WB_wea_Out <= ({{(`PE_COL-1){1'b0}},1'b1} << Cmd_Column);
            end
        end

        if (!INFER && In_Valid && (In_Offset == OFFSET_LOAD_B)) begin
            if (Bias_Header) begin
                Bias_Load_Pending <= 1'b1;
                Bias_Load_Layer <= Bias_Cmd_Layer[2:0];
                Bias_Load_Number <= Bias_Cmd_Number;
            end
            else if (Bias_Load_Pending) begin
                Bias_Mem[Bias_Layer_Base(Bias_Load_Layer) + Bias_Load_Number[6:0]] <= Bias_Cmd_Value;
                Bias_Load_Pending <= 1'b0;
            end
        end

        // -----------------------------------------------------------------
        // RGB activation load. BUSY means "do not send another activation".
        // One 1024-byte raw channel buffer is reused R -> G -> B.
        // -----------------------------------------------------------------
        if (In_Valid && (In_Offset == OFFSET_LOAD_A) && !BUSY) begin
            if ((!INFER && (Cmd_Column[1:0] == 2'd0)) ||
                (INFER && (Cmd_Column[1:0] == Expected_Color))) begin
                Raw_Buffer[Cmd_Addr[9:0]] <= Cmd_Data;
                if (!INFER) begin
                    INFER <= 1'b1;
                    DONE <= 1'b0;
                    Cum_Shift <= 0;
                    Result_Index <= 0;
                    Result_Value <= 0;
                    Expected_Color <= 0;
                    Raw_Load_Count <= 1;
                    State <= ST_IDLE;
                end
                else begin
                    Raw_Load_Count <= Raw_Load_Count + 1'b1;
                end

                if (INFER && (Raw_Load_Count == 11'd1023)) begin
                    Raw_Ready <= 1'b1;
                    BUSY <= 1'b1;

                    if (Cmd_Column[1:0] == 2'd0) begin
                        Layer <= 3'd0;
                        K_Index <= 0;
                        Cnt_OC <= 0;
                        Cnt_S <= 0;
                        Cnt_W_Row <= 0;
                        WB_Tile_Base <= WBASE_CONV1;
                        PB_Tile_Base <= PB_REGION_A;
                        W_Done_Latched <= 1'b0;
                        AB_Ready <= 1'b0;
                        Prep_Target_K <= 0;
                        Prep_Needed <= 1'b1;
                        Bias_Prep_Ready <= 1'b0;
                        State <= ST_WLOAD;
                    end
                end
            end
        end

        // -----------------------------------------------------------------
        // Start a requested im2col preparation when its source is available.
        // -----------------------------------------------------------------
        if (Prep_Needed && !Prep_Busy) begin
            if ((Layer != 3'd0) || Raw_Ready) begin
                Prep_Busy <= 1'b1;
                Prep_Is_Raw <= (Layer == 3'd0);
                Prep_Needed <= 1'b0;
                AB_Ready <= 1'b0;
                I2C_Start <= 1'b1;
                I2C_Width <= Layer_Width(Layer);
                Raw_Read_Index <= 0;
                FIFO_WPtr <= 0;
                FIFO_RPtr <= 0;
                FIFO_Level <= 0;
                Src_Request_Count <= 0;
                Src_Out_Row <= 0;
                Src_Out_Col <= 0;
                Src_Pool_Phase <= 0;
                Src_Request_Done <= 1'b0;
            end
        end

        // Raw-source replay into the shared im2col.
        if (Prep_Busy && Prep_Is_Raw && I2C_Pixel_Ready && I2C_Pixel_Valid)
            Raw_Read_Index <= Raw_Read_Index + 1'b1;

        // PB-source FIFO push/pop.
        if (FIFO_Push) begin
            Source_FIFO[FIFO_WPtr] <= In_PB_Data[`BIT_DATA-1:0];
            FIFO_WPtr <= FIFO_WPtr + 1'b1;
        end
        if (FIFO_Pop) FIFO_RPtr <= FIFO_RPtr + 1'b1;
        case ({FIFO_Push,FIFO_Pop})
            2'b10: FIFO_Level <= FIFO_Level + 1'b1;
            2'b01: FIFO_Level <= FIFO_Level - 1'b1;
            default: FIFO_Level <= FIFO_Level;
        endcase

        // PB source requests for next convolution input channel.
        if (Prep_Busy && !Prep_Is_Raw && !Src_Request_Done && (FIFO_Level < FIFO_LIMIT)) begin
            PB_Valid_Out <= Src_Onehot_Bank;
            PB_En_Tile_Out <= 0;
            PB_En_Requant_Out <= 1'b1;
            PB_En_Maxpool_Out <= Src_Maxpool;
            PB_To_Ctrl_Out <= 1'b1;

            if (!Src_Maxpool) begin
                PB_Addr_Out <= Src_Channel_Base + Src_Request_Count;
                if (Src_Request_Count == (Layer_S(Layer)-1)) Src_Request_Done <= 1'b1;
                else Src_Request_Count <= Src_Request_Count + 1'b1;
            end
            else begin
                PB_Addr_Out <= Src_Channel_Base + Src_Pool_Offset;
                Src_Request_Count <= Src_Request_Count + 1'b1;
                if (Src_Pool_Phase == 2'd3) begin
                    Src_Pool_Phase <= 0;
                    if (Src_Out_Col == (Src_Out_Width-1)) begin
                        Src_Out_Col <= 0;
                        if (Src_Out_Row == (Src_Out_Width-1)) begin
                            Src_Request_Done <= 1'b1;
                        end
                        else Src_Out_Row <= Src_Out_Row + 1'b1;
                    end
                    else Src_Out_Col <= Src_Out_Col + 1'b1;
                end
                else Src_Pool_Phase <= Src_Pool_Phase + 1'b1;
            end
        end

        // im2col -> AB: 9 activations written together.
        if (Prep_Busy && I2C_Window_Valid) begin
            AB_addra_Out <= I2C_Window_Addr;
            AB_dina_Out <= I2C_Window_Data;
            AB_ena_Out <= {`PE_ROW{1'b1}};
            AB_wea_Out <= {`PE_ROW{1'b1}};
        end

        if (Prep_Busy && I2C_Done) begin
            Prep_Busy <= 1'b0;
            AB_Ready <= 1'b1;

            if (Prep_Is_Raw) begin
                Raw_Ready <= 1'b0;
                Raw_Load_Count <= 0;
                if (Prep_Target_K < 2) begin
                    Expected_Color <= Prep_Target_K[1:0] + 1'b1;
                    BUSY <= 1'b0;
                end
                else begin
                    BUSY <= 1'b1;
                end
            end
        end

        // -----------------------------------------------------------------
        // Main compute scheduler
        // -----------------------------------------------------------------
        case (State)
            ST_IDLE: begin
                // Waiting for R load to complete.
            end

            ST_WLOAD: begin
                // Start bias preparation only for K tile 0.
                if ((Cnt_W_Row == 0) && (K_Index == 0) && !Bias_Prep_Active && !Bias_Prep_Ready) begin
                    Bias_Prep_Active <= 1'b1;
                    Bias_Prep_Issue <= 0;
                    Bias_Prep_Base_Index <= Bias_Layer_Base(Layer) + Cnt_OC;
                end

                if ((K_Index == 0) && (Cnt_OC == 0) && (Cnt_W_Row == 0) && (Layer != 3'd7))
                    Biggest_Count_Out <= Cur_OC;

                if (Cnt_W_Row < `PE_ROW) begin
                    WB_addra_Out <= WB_Tile_Base + Cnt_W_Row;
                    WB_ena_Out <= Active_Col_Mask;
                    SA_En_W_Out <= Active_Col_Mask;
                    SA_En_ID_Out <= Cnt_W_Row;
                    Cnt_W_Row <= Cnt_W_Row + 1'b1;
                end
                else begin
                    W_Done_Latched <= 1'b0;
                    State <= ST_WAIT_W;
                end
            end

            ST_WAIT_W: begin
                if (In_SA_Done_W) W_Done_Latched <= 1'b1;

                if ((W_Done_Latched || In_SA_Done_W) && AB_Ready && ((K_Index != 0) || Bias_Prep_Ready)) begin
                    Cnt_S <= 0;
                    State <= ST_MAC;
                end
            end

            ST_MAC: begin
                if (Cnt_S < Cur_S) begin
                    AB_addra_Out <= MAC_AB_Addr;
                    AB_ena_Out <= {`PE_ROW{1'b1}};

                    SA_Addr_P_Out <= MAC_PB_Addr;
                    SA_Valid_P_Out <= Active_Col_Mask;
                    SA_En_ReLU_Out <= Final_K && Cur_ReLU;

                    if (K_Index != 0) begin
                        PB_Addr_Out <= MAC_PB_Addr;
                        PB_Valid_Out <= Active_Col_Mask;
                        PB_En_Tile_Out <= Active_Col_Mask;
                    end

                    // After the last request of the final OC tile, the PB/AB read
                    // ports are free. Start preparing the next K/channel immediately.
                    if ((Cnt_S == (Cur_S-1)) && Final_OC && More_K && !Cur_Is_FC) begin
                        Prep_Target_K <= K_Index + 1'b1;
                        AB_Ready <= 1'b0;

                        // The current AB/PB feedback requests end on this cycle.
                        // If the next source is already available, arm im2col now so
                        // the next PB source request can be issued on the next cycle.
                        if ((Layer != 3'd0) || Raw_Ready) begin
                            Prep_Busy <= 1'b1;
                            Prep_Is_Raw <= (Layer == 3'd0);
                            Prep_Needed <= 1'b0;
                            I2C_Start <= 1'b1;
                            I2C_Width <= Layer_Width(Layer);
                            Raw_Read_Index <= 0;
                            FIFO_WPtr <= 0;
                            FIFO_RPtr <= 0;
                            FIFO_Level <= 0;
                            Src_Request_Count <= 0;
                            Src_Out_Row <= 0;
                            Src_Out_Col <= 0;
                            Src_Pool_Phase <= 0;
                            Src_Request_Done <= 1'b0;
                        end
                        else begin
                            Prep_Needed <= 1'b1;
                        end
                    end

                    if (Cnt_S == (Cur_S-1)) begin
                        Cnt_S <= Cur_S;
                        State <= ST_DRAIN;
                    end
                    else Cnt_S <= Cnt_S + 1'b1;
                end
            end

            ST_DRAIN: begin
                if (In_SA_Done_I[Last_Active_Col]) begin
                    Cnt_S <= 0;
                    Cnt_W_Row <= 0;
                    W_Done_Latched <= 1'b0;

                    if (More_OC) begin
                        Cnt_OC <= Cnt_OC + `PE_COL;
                        PB_Tile_Base <= PB_Tile_Base + Cur_S;
                        WB_Tile_Base <= WB_Tile_Base + `PE_ROW;
                        if (K_Index == 0) Bias_Prep_Ready <= 1'b0;
                        State <= ST_WLOAD;
                    end
                    else if (More_K) begin
                        K_Index <= K_Index + 1'b1;
                        Cnt_OC <= 0;
                        PB_Tile_Base <= Layer_Dest_Base(Layer);
                        WB_Tile_Base <= WB_Tile_Base + `PE_ROW;
                        State <= ST_WLOAD;
                    end
                    else begin
                        State <= ST_WAIT_LAYER;
                    end
                end
            end

            ST_WAIT_LAYER: begin
                if (Layer == 3'd7) begin
                    if (In_FinishFlag[Last_Active_Col]) begin
                        Final_Req_Index <= 0;
                        Final_Ret_Index <= 0;
                        State <= ST_FINAL_FETCH;
                    end
                end
                else if (In_Biggest_Valid) begin
                    if (Layer <= 3'd4) begin
                        Layer <= Layer + 1'b1;
                        K_Index <= 0;
                        Cnt_OC <= 0;
                        Cnt_S <= 0;
                        Cnt_W_Row <= 0;
                        WB_Tile_Base <= Layer_WBase(Layer + 1'b1);
                        PB_Tile_Base <= Layer_Dest_Base(Layer + 1'b1);
                        Bias_Prep_Ready <= 1'b0;
                        AB_Ready <= 1'b0;
                        Prep_Target_K <= 0;
                        Prep_Needed <= 1'b1;
                        State <= ST_WLOAD;
                    end
                    else if (Layer == 3'd5) begin
                        Gap_Req_Channel <= 0;
                        Gap_Req_In_Channel <= 0;
                        Gap_Ret_Channel <= 0;
                        Gap_Ret_Count <= 0;
                        Gap_Sum <= 0;
                        Pack_Bank <= 0;
                        Pack_Addr <= 0;
                        State <= ST_GAP;
                    end
                    else begin
                        FC1_Req_Index <= 0;
                        FC1_Ret_Index <= 0;
                        Pack_Bank <= 0;
                        Pack_Addr <= 0;
                        State <= ST_FC1_FETCH;
                    end
                end
            end

            // Conv6 PB -> requant -> maxpool -> 16-value GAP -> FC1 AB packing.
            ST_GAP: begin
                if (Gap_Req_Channel < 96) begin
                    PB_Valid_Out <= ({{(`PE_COL-1){1'b0}},1'b1} << Gap_Req_Channel[3:0]);
                    PB_Addr_Out <= Gap_Source_Addr(Gap_Req_Channel, Gap_Req_In_Channel);
                    PB_En_Requant_Out <= 1'b1;
                    PB_En_Maxpool_Out <= 1'b1;
                    PB_To_Ctrl_Out <= 1'b1;

                    if (Gap_Req_In_Channel == 7'd63) begin
                        Gap_Req_In_Channel <= 0;
                        Gap_Req_Channel <= Gap_Req_Channel + 1'b1;
                    end
                    else Gap_Req_In_Channel <= Gap_Req_In_Channel + 1'b1;
                end

                if (In_PB_To_Ctrl && (|In_PB_Valid)) begin
                    if (Gap_Ret_Count == 5'd15) begin
                        AB_addra_Out <= Pack_Addr;
                        AB_dina_Out <= {`PE_ROW{Gap_Value}};
                        AB_ena_Out <= ({{(`PE_ROW-1){1'b0}},1'b1} << Pack_Bank);
                        AB_wea_Out <= ({{(`PE_ROW-1){1'b0}},1'b1} << Pack_Bank);
                        Gap_Sum <= 0;
                        Gap_Ret_Count <= 0;

                        if (Pack_Bank == 8) begin
                            Pack_Bank <= 0;
                            Pack_Addr <= Pack_Addr + 1'b1;
                        end
                        else Pack_Bank <= Pack_Bank + 1'b1;

                        if (Gap_Ret_Channel == 8'd95) State <= ST_GAP_ZERO;
                        else Gap_Ret_Channel <= Gap_Ret_Channel + 1'b1;
                    end
                    else begin
                        Gap_Sum <= Gap_Sum_Next;
                        Gap_Ret_Count <= Gap_Ret_Count + 1'b1;
                    end
                end
            end

            ST_GAP_ZERO: begin
                // FC1: K=96 -> 11th AB row has bank 6..8 = 0.
                AB_addra_Out <= 10;
                AB_dina_Out <= 0;
                AB_ena_Out <= 9'b111000000;
                AB_wea_Out <= 9'b111000000;

                Layer <= 3'd6;
                K_Index <= 0;
                Cnt_OC <= 0;
                Cnt_S <= 0;
                Cnt_W_Row <= 0;
                WB_Tile_Base <= WBASE_FC1;
                PB_Tile_Base <= PB_REGION_A;
                AB_Ready <= 1'b1;
                Bias_Prep_Ready <= 1'b0;
                State <= ST_WLOAD;
            end

            // FC1 PB -> requant -> pack 128 scalars into 9-bank AB for FC2.
            ST_FC1_FETCH: begin
                if (FC1_Req_Index < 128) begin
                    PB_Valid_Out <= ({{(`PE_COL-1){1'b0}},1'b1} << FC1_Req_Index[3:0]);
                    PB_Addr_Out <= PB_REGION_A + (FC1_Req_Index >> 4);
                    PB_En_Requant_Out <= 1'b1;
                    PB_To_Ctrl_Out <= 1'b1;
                    FC1_Req_Index <= FC1_Req_Index + 1'b1;
                end

                if (In_PB_To_Ctrl && (|In_PB_Valid)) begin
                    AB_addra_Out <= Pack_Addr;
                    AB_dina_Out <= {`PE_ROW{In_PB_Data[`BIT_DATA-1:0]}};
                    AB_ena_Out <= ({{(`PE_ROW-1){1'b0}},1'b1} << Pack_Bank);
                    AB_wea_Out <= ({{(`PE_ROW-1){1'b0}},1'b1} << Pack_Bank);

                    if (Pack_Bank == 8) begin
                        Pack_Bank <= 0;
                        Pack_Addr <= Pack_Addr + 1'b1;
                    end
                    else Pack_Bank <= Pack_Bank + 1'b1;

                    if (FC1_Ret_Index == 8'd127) State <= ST_FC1_ZERO;
                    else FC1_Ret_Index <= FC1_Ret_Index + 1'b1;
                end
            end

            ST_FC1_ZERO: begin
                // FC2: K=128 -> 15th AB row has bank 2..8 = 0.
                AB_addra_Out <= 14;
                AB_dina_Out <= 0;
                AB_ena_Out <= 9'b111111100;
                AB_wea_Out <= 9'b111111100;

                Layer <= 3'd7;
                K_Index <= 0;
                Cnt_OC <= 0;
                Cnt_S <= 0;
                Cnt_W_Row <= 0;
                WB_Tile_Base <= WBASE_FC2;
                PB_Tile_Base <= PB_REGION_B;
                AB_Ready <= 1'b1;
                Bias_Prep_Ready <= 1'b0;
                State <= ST_WLOAD;
            end

            // FC2 raw signed 25-bit logits. No ReLU / maxdetect / requant.
            ST_FINAL_FETCH: begin
                if (Final_Req_Index < 10) begin
                    PB_Valid_Out <= ({{(`PE_COL-1){1'b0}},1'b1} << Final_Req_Index);
                    PB_Addr_Out <= PB_REGION_B;
                    PB_To_Ctrl_Out <= 1'b1;
                    Final_Req_Index <= Final_Req_Index + 1'b1;
                end

                if (In_PB_To_Ctrl && (|In_PB_Valid)) begin
                    Logit_Mem[Final_Ret_Index] <= In_PB_Data;
                    if (Final_Ret_Index == 4'd9) begin
                        DONE <= 1'b1;
                        BUSY <= 1'b0;
                        INFER <= 1'b0;
                        Result_Index <= 0;
                        Result_Value <= Logit_Mem[0];
                        Expected_Color <= 0;
                        Raw_Load_Count <= 0;
                        State <= ST_IDLE;
                    end
                    else Final_Ret_Index <= Final_Ret_Index + 1'b1;
                end
            end

            default: State <= ST_IDLE;
        endcase
    end
end

endmodule
