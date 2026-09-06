`timescale 1ns / 1ps
`include "param.v"

module MatMul #(
    parameter integer BIT_OFFSET = 2,
    parameter integer BIT_INSTR  = 32,
    parameter integer BIT_MSB    = 5,
    parameter integer BIT_SHIFT  = 5
)(
    input  wire                  CLK,
    input  wire                  RST,

    // AXI write-command pulse
    input  wire                  In_Valid,
    input  wire [BIT_OFFSET-1:0] In_Offset,
    input  wire [BIT_INSTR-1:0]  In_Instruction,

    // One-cycle pulse when the AXI slave has accepted/latches an RCODE read.
    // Ctrl uses this as an ACK to advance class0 -> class1 -> ... -> class9.
    input  wire                  In_Rcode_Read,

    output wire [BIT_INSTR-1:0]  Rcode_Out
);

    // ========================================================================
    // Controller wires
    // ========================================================================
    wire [`ADDR_WSRAM-1:0]       Ctrl_WB_Addr;
    wire [`PE_COL*`BIT_DATA-1:0] Ctrl_WB_Data;
    wire [`PE_COL-1:0]           Ctrl_WB_En;
    wire [`PE_COL-1:0]           Ctrl_WB_We;

    wire [`ADDR_ASRAM-1:0]       Ctrl_AB_Addr;
    wire [`PE_ROW*`BIT_DATA-1:0] Ctrl_AB_Data;
    wire [`PE_ROW-1:0]           Ctrl_AB_En;
    wire [`PE_ROW-1:0]           Ctrl_AB_We;

    wire [`PE_COL-1:0]           Ctrl_SA_En_W;
    wire [`BIT_ROW_ID-1:0]       Ctrl_SA_En_ID;
    wire [`ADDR_PSRAM-1:0]       Ctrl_SA_Addr_P;
    wire [`PE_COL-1:0]           Ctrl_SA_Valid_P;
    wire                         Ctrl_SA_En_ReLU;

    wire [`PE_COL-1:0]           Ctrl_PB_Valid;
    wire [`ADDR_PSRAM-1:0]       Ctrl_PB_Addr;
    wire [`PE_COL-1:0]           Ctrl_PB_En_Tile;
    wire                         Ctrl_PB_En_Maxpool;
    wire                         Ctrl_PB_En_Requant;
    wire                         Ctrl_PB_To_Ctrl;
    wire [`PE_COL*`BIT_PSUM-1:0] Ctrl_PB_Bias;

    wire [7:0]                   Ctrl_Biggest_Count;

    // SA / PB feedbacks to Ctrl
    wire [`PE_COL-1:0]           SA_Done_W;
    wire [`PE_COL-1:0]           SA_Done_I;
    wire [`PE_COL-1:0]           FinishFlag;

    wire [`PE_COL-1:0]           PB_Ctrl_Valid;
    wire [`ADDR_PSRAM-1:0]       PB_Ctrl_Addr;
    wire [`BIT_PSUM-1:0]         PB_Ctrl_Data;
    wire                         PB_Ctrl_To_Ctrl;

    // biggest -> Ctrl
    wire                         Biggest_Valid_Ctrl;
    wire [BIT_SHIFT-1:0]         Biggest_Shift_Ctrl;

    Ctrl #(
        .BIT_OFFSET(BIT_OFFSET),
        .BIT_INSTR(BIT_INSTR),
        .BIT_SHIFT(BIT_SHIFT)
    ) u_Ctrl (
        .CLK(CLK),
        .RST(RST),
        .In_Valid(In_Valid),
        .In_Offset(In_Offset),
        .In_Instruction(In_Instruction),
        .In_Rcode_Read(In_Rcode_Read),
        .Rcode_Out(Rcode_Out),

        .WB_addra_Out(Ctrl_WB_Addr),
        .WB_dina_Out(Ctrl_WB_Data),
        .WB_ena_Out(Ctrl_WB_En),
        .WB_wea_Out(Ctrl_WB_We),

        .AB_addra_Out(Ctrl_AB_Addr),
        .AB_dina_Out(Ctrl_AB_Data),
        .AB_ena_Out(Ctrl_AB_En),
        .AB_wea_Out(Ctrl_AB_We),

        .SA_En_W_Out(Ctrl_SA_En_W),
        .SA_En_ID_Out(Ctrl_SA_En_ID),
        .SA_Addr_P_Out(Ctrl_SA_Addr_P),
        .SA_Valid_P_Out(Ctrl_SA_Valid_P),
        .SA_En_ReLU_Out(Ctrl_SA_En_ReLU),
        .In_SA_Done_W(SA_Done_W[0]),
        .In_SA_Done_I(SA_Done_I),

        .PB_Valid_Out(Ctrl_PB_Valid),
        .PB_Addr_Out(Ctrl_PB_Addr),
        .PB_En_Tile_Out(Ctrl_PB_En_Tile),
        .PB_En_Maxpool_Out(Ctrl_PB_En_Maxpool),
        .PB_En_Requant_Out(Ctrl_PB_En_Requant),
        .PB_To_Ctrl_Out(Ctrl_PB_To_Ctrl),
        .PB_Bias_Out(Ctrl_PB_Bias),

        .In_PB_Valid(PB_Ctrl_Valid),
        .In_PB_addr(PB_Ctrl_Addr),
        .In_PB_Data(PB_Ctrl_Data),
        .In_PB_To_Ctrl(PB_Ctrl_To_Ctrl),

        .In_FinishFlag(FinishFlag),

        .Biggest_Count_Out(Ctrl_Biggest_Count),
        .In_Biggest_Valid(Biggest_Valid_Ctrl),
        .In_Biggest_Max_Shift(Biggest_Shift_Ctrl)
    );

    // ========================================================================
    // Weight path: Ctrl -> ctrl_to_wb -> Weight BRAM -> wb_to_sa -> SA
    // ========================================================================
    wire [`PE_COL*`ADDR_WSRAM-1:0] WB_Addr;
    wire [`PE_COL*`BIT_DATA-1:0]    WB_Din;
    wire [`PE_COL*`BIT_DATA-1:0]    WB_Dout;
    wire [`PE_COL*`BIT_DATA-1:0]    WB_To_SA;
    wire [`PE_COL-1:0]              WB_En;
    wire [`PE_COL-1:0]              WB_We;

    genvar w;
    generate
        for (w=0; w<`PE_COL; w=w+1) begin : GEN_WB
            ctrl_to_wb u_ctrl_to_wb (
                .CLK(CLK),
                .RST(RST),
                .In_addra(Ctrl_WB_Addr),
                .In_dina(Ctrl_WB_Data[w*`BIT_DATA +: `BIT_DATA]),
                .In_ena(Ctrl_WB_En[w]),
                .In_wea(Ctrl_WB_We[w]),
                .addra_Out(WB_Addr[w*`ADDR_WSRAM +: `ADDR_WSRAM]),
                .dina_Out(WB_Din[w*`BIT_DATA +: `BIT_DATA]),
                .ena_Out(WB_En[w]),
                .wea_Out(WB_We[w])
            );

            blk_mem_gen_1 u_WeightBuffer (
                .clka(CLK),
                .ena(WB_En[w]),
                .wea(WB_We[w]),
                .addra(WB_Addr[w*`ADDR_WSRAM +: `ADDR_WSRAM]),
                .dina(WB_Din[w*`BIT_DATA +: `BIT_DATA]),
                .douta(WB_Dout[w*`BIT_DATA +: `BIT_DATA])
            );

            wb_to_sa u_wb_to_sa (
                .CLK(CLK),
                .RST(RST),
                .In_douta(WB_Dout[w*`BIT_DATA +: `BIT_DATA]),
                .douta_Out(WB_To_SA[w*`BIT_DATA +: `BIT_DATA])
            );
        end
    endgenerate

    // ========================================================================
    // Activation path: Ctrl -> ctrl_to_ab -> Activation BRAM -> InputLoader
    // ========================================================================
    wire [`PE_ROW*`ADDR_ASRAM-1:0] AB_Addr;
    wire [`PE_ROW*`BIT_DATA-1:0]    AB_Din;
    wire [`PE_ROW*`BIT_DATA-1:0]    AB_Dout;
    wire [`PE_ROW*`BIT_DATA-1:0]    AB_To_SA;
    wire [`PE_ROW-1:0]              AB_En;
    wire [`PE_ROW-1:0]              AB_We;

    genvar a;
    generate
        for (a=0; a<`PE_ROW; a=a+1) begin : GEN_AB
            ctrl_to_ab u_ctrl_to_ab (
                .CLK(CLK),
                .RST(RST),
                .In_addra(Ctrl_AB_Addr),
                .In_dina(Ctrl_AB_Data[a*`BIT_DATA +: `BIT_DATA]),
                .In_ena(Ctrl_AB_En[a]),
                .In_wea(Ctrl_AB_We[a]),
                .addra_Out(AB_Addr[a*`ADDR_ASRAM +: `ADDR_ASRAM]),
                .dina_Out(AB_Din[a*`BIT_DATA +: `BIT_DATA]),
                .ena_Out(AB_En[a]),
                .wea_Out(AB_We[a])
            );

            blk_mem_gen_0 u_ActivationBuffer (
                .clka(CLK),
                .ena(AB_En[a]),
                .wea(AB_We[a]),
                .addra(AB_Addr[a*`ADDR_ASRAM +: `ADDR_ASRAM]),
                .dina(AB_Din[a*`BIT_DATA +: `BIT_DATA]),
                .douta(AB_Dout[a*`BIT_DATA +: `BIT_DATA])
            );
        end
    endgenerate

    InputLoader u_InputLoader (
        .CLK(CLK),
        .i_Data_I_In(AB_Dout),
        .o_Data_I_In(AB_To_SA)
    );

    // ========================================================================
    // Ctrl -> ctrl_to_sa -> SA metadata/control
    // En_ReLU follows the exact same column-dependent latency as Valid_P.
    // ========================================================================
    wire [`PE_COL-1:0]                 SA_En_W;
    wire [`PE_COL*`BIT_ROW_ID-1:0]     SA_En_ID_Per_Col;
    wire [`PE_COL*`ADDR_PSRAM-1:0]     SA_Addr_P_In;
    wire [`PE_COL-1:0]                 SA_Valid_P_In;
    wire [`PE_COL-1:0]                 SA_En_ReLU_In;
    wire [`BIT_ROW_ID-1:0]             SA_En_ID;

    assign SA_En_ID = SA_En_ID_Per_Col[0 +: `BIT_ROW_ID];

    genvar c;
    generate
        for (c=0; c<`PE_COL; c=c+1) begin : GEN_CTRL_TO_SA
            ctrl_to_sa #(
                .COLNUM(c)
            ) u_ctrl_to_sa (
                .CLK(CLK),
                .RST(RST),
                .In_En_W(Ctrl_SA_En_W[c]),
                .In_En_ID(Ctrl_SA_En_ID),
                .In_Addr_P(Ctrl_SA_Addr_P),
                .In_Valid_P(Ctrl_SA_Valid_P[c]),
                .In_En_ReLU(Ctrl_SA_En_ReLU),
                .En_W_Out(SA_En_W[c]),
                .En_ID_Out(SA_En_ID_Per_Col[c*`BIT_ROW_ID +: `BIT_ROW_ID]),
                .Addr_P_Out(SA_Addr_P_In[c*`ADDR_PSRAM +: `ADDR_PSRAM]),
                .Valid_P_Out(SA_Valid_P_In[c]),
                .Out_En_ReLU(SA_En_ReLU_In[c]),
                .Done_W_Out(SA_Done_W[c]),
                .Done_I_Out(SA_Done_I[c])
            );
        end
    endgenerate

    // ========================================================================
    // Product-buffer read path
    //
    // One shared ctrl_to_pb handles the 16 PB banks.
    // - feedback MAC reads may enable many banks in parallel;
    // - source/next-layer reads are one-hot and become scalar Ctrl data;
    // - Bias/En_Tile are aligned to ProductLoader timing;
    // - PB bank-select and requant are split by the extra Fmax register.
    // ========================================================================
    wire [`ADDR_PSRAM-1:0]       PB_RAddr;
    wire [`PE_COL-1:0]           PB_RValid;
    wire [`PE_COL-1:0]           PB_En_Tile;
    wire [`PE_COL*`BIT_PSUM-1:0] PB_Bias;
    wire [`PE_COL*`BIT_PSUM-1:0] PB_RData;
    wire [`PE_COL*`BIT_PSUM-1:0] PB_To_SA;

    // biggest -> ctrl_to_pb
    wire                         Biggest_Valid_PB;
    wire [BIT_SHIFT-1:0]         Biggest_Shift_PB;

    ctrl_to_pb #(
        .BIT_ADDR(`ADDR_PSRAM),
        .BIT_DATA(`BIT_PSUM),
        .NB(2),
        .BIT_SHIFT(BIT_SHIFT)
    ) u_ctrl_to_pb (
        .CLK(CLK),
        .RST(RST),
        .In_Valid(Ctrl_PB_Valid),
        .In_Addr(Ctrl_PB_Addr),
        .In_En_Tile(Ctrl_PB_En_Tile),
        .In_En_Maxpool(Ctrl_PB_En_Maxpool),
        .In_En_Requant(Ctrl_PB_En_Requant),
        .In_To_Ctrl(Ctrl_PB_To_Ctrl),
        .Bias_In(Ctrl_PB_Bias),
        .PB_Addr_Out(PB_RAddr),
        .PB_Valid_Out(PB_RValid),
        .En_Tile_Out(PB_En_Tile),
        .Bias_Out(PB_Bias),
        .PB_Data_In(PB_RData),
        .ctrl_Valid_Out(PB_Ctrl_Valid),
        .ctrl_Addr_Out(PB_Ctrl_Addr),
        .Data_Out(PB_Ctrl_Data),
        .ctrl_To_Ctrl_Out(PB_Ctrl_To_Ctrl),
        .In_biggest_Valid(Biggest_Valid_PB),
        .In_biggest_Max_Shift(Biggest_Shift_PB)
    );

    genvar p;
    generate
        for (p=0; p<`PE_COL; p=p+1) begin : GEN_PRODUCT_LOADER
            ProductLoader #(
                .BIT_DATA(`BIT_PSUM),
                .DELAY(2),
                .COLNUM(p)
            ) u_ProductLoader (
                .CLK(CLK),
                .RST(RST),
                .En_Tile_In(PB_En_Tile[p]),
                .Data_In(PB_RData[p*`BIT_PSUM +: `BIT_PSUM]),
                .Bias_In(PB_Bias[p*`BIT_PSUM +: `BIT_PSUM]),
                .Data_Out(PB_To_SA[p*`BIT_PSUM +: `BIT_PSUM])
            );
        end
    endgenerate

    // ========================================================================
    // 9 x 16 weight-stationary systolic array
    // ========================================================================
    wire [`PE_COL*`BIT_PSUM-1:0]   SA_Psum_Out;
    wire [`PE_COL*`ADDR_PSRAM-1:0] SA_Addr_P_Out;
    wire [`PE_COL-1:0]             SA_Valid_P_Out;
    wire [`PE_COL-1:0]             SA_En_ReLU_Out;

    systolic u_Systolic (
        .CLK(CLK),
        .RST(RST),
        .i_Data_I_In(AB_To_SA),
        .i_Data_W_In(WB_To_SA),
        .i_EN_W_In(SA_En_W),
        .i_EN_ID_In(SA_En_ID),
        .i_Psum_In(PB_To_SA),
        .o_Psum_Out(SA_Psum_Out),
        .i_Addr_P_In(SA_Addr_P_In),
        .i_Valid_P_In(SA_Valid_P_In),
        .i_En_ReLU_In(SA_En_ReLU_In),
        .o_Addr_P_Out(SA_Addr_P_Out),
        .o_Valid_P_Out(SA_Valid_P_Out),
        .o_En_ReLU_Out(SA_En_ReLU_Out)
    );

    // ========================================================================
    // SA -> sa_to_pb -> Product Buffer write port
    // sa_to_pb also emits local Max_MSB / Max_Valid directly to biggest.
    // ========================================================================
    wire [`PE_COL*`ADDR_PSRAM-1:0] PB_WAddr;
    wire [`PE_COL-1:0]             PB_WValid;
    wire [`PE_COL*`BIT_PSUM-1:0]   PB_WData;
    wire [`PE_COL*BIT_MSB-1:0]     Local_Max_MSB;
    wire [`PE_COL-1:0]             Local_Max_Valid;

    genvar q;
    generate
        for (q=0; q<`PE_COL; q=q+1) begin : GEN_PB
            sa_to_pb #(
                .BIT_ADDR(`ADDR_PSRAM),
                .BIT_DATA(`BIT_PSUM),
                .BIT_MSB(BIT_MSB),
                .DELAY(2)
            ) u_sa_to_pb (
                .CLK(CLK),
                .RST(RST),
                .In_Addr_P(SA_Addr_P_Out[q*`ADDR_PSRAM +: `ADDR_PSRAM]),
                .In_Valid_P(SA_Valid_P_Out[q]),
                .In_Psum(SA_Psum_Out[q*`BIT_PSUM +: `BIT_PSUM]),
                .In_En_ReLU(SA_En_ReLU_Out[q]),
                .Addr_P_Out(PB_WAddr[q*`ADDR_PSRAM +: `ADDR_PSRAM]),
                .Valid_P_Out(PB_WValid[q]),
                .Psum_Out(PB_WData[q*`BIT_PSUM +: `BIT_PSUM]),
                .FinishFlag_Out(FinishFlag[q]),
                .Max_MSB_Out(Local_Max_MSB[q*BIT_MSB +: BIT_MSB]),
                .Max_Valid_Out(Local_Max_Valid[q])
            );

            blk_mem_gen_2 u_ProductBuffer (
                .clka(CLK),
                .ena(PB_WValid[q]),
                .wea(PB_WValid[q]),
                .addra(PB_WAddr[q*`ADDR_PSRAM +: `ADDR_PSRAM]),
                .dina(PB_WData[q*`BIT_PSUM +: `BIT_PSUM]),

                .clkb(CLK),
                .enb(PB_RValid[q]),
                .addrb(PB_RAddr),
                .doutb(PB_RData[q*`BIT_PSUM +: `BIT_PSUM])
            );
        end
    endgenerate

    // ========================================================================
    // Layer-global max detector / dynamic shift generator
    // ========================================================================
    biggest #(
        .PE_COL(`PE_COL),
        .BIT_MSB(BIT_MSB),
        .BIT_CNT(8),
        .BIT_SHIFT(BIT_SHIFT)
    ) u_biggest (
        .CLK(CLK),
        .RST(RST),
        .In_Count(Ctrl_Biggest_Count),
        .In_Valid(Local_Max_Valid),
        .In_MSB(Local_Max_MSB),
        .PB_Max_Shift_Out(Biggest_Shift_PB),
        .Valid_PB_Out(Biggest_Valid_PB),
        .Ctrl_Max_Shift_Out(Biggest_Shift_Ctrl),
        .Valid_Ctrl_Out(Biggest_Valid_Ctrl)
    );

endmodule
