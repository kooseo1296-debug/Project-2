`timescale 1ns / 1ps
`include "param.v"

module Ctrl #(
    parameter integer BIT_OFFSET   = 3,
    parameter integer BIT_INSTR    = 32,
    parameter integer BIT_COLNUM   = 8,
    parameter integer BIT_ADDR     = 15,
    parameter integer BIT_CMD_ADDR = 16
)(
    // AXI -> ctrl
    input  wire                         CLK,
    input  wire                         RST,
    input  wire                         In_Valid,
    input  wire [BIT_OFFSET-1:0]        In_Offset,
    input  wire [BIT_INSTR-1:0]         In_Instruction,

    // ctrl -> AXI
    output wire [BIT_INSTR-1:0]         Rcode_Out,

    // ctrl -> WB
    output reg  [`ADDR_WSRAM-1:0]       WB_addra_Out,
    output reg  [`PE_COL*`BIT_DATA-1:0] WB_dina_Out,
    output reg  [`PE_COL-1:0]           WB_ena_Out,
    output reg  [`PE_COL-1:0]           WB_wea_Out,

    // ctrl -> AB
    output reg  [`ADDR_ASRAM-1:0]       AB_addra_Out,
    output reg  [`PE_ROW*`BIT_DATA-1:0] AB_dina_Out,
    output reg  [`PE_ROW-1:0]           AB_ena_Out,
    output reg  [`PE_ROW-1:0]           AB_wea_Out,

    // ctrl -> SA
    output reg  [`PE_COL-1:0]           SA_En_W_Out,
    output reg  [`BIT_ROW_ID-1:0]       SA_En_ID_Out,
    output reg  [`ADDR_PSRAM-1:0]       SA_Addr_P_Out,
    output reg  [`PE_COL-1:0]           SA_Valid_P_Out,
    input  wire                         In_SA_Done_W,
    input  wire [`PE_COL-1:0]           In_SA_Done_I,

    // ctrl -> PB
    output reg  [`PE_COL-1:0]           PB_Valid_Out,
    output reg  [`ADDR_PSRAM-1:0]       PB_Addr_Out,
    output reg  [`PE_COL-1:0]           PB_En_Tile_Out,

    // PB -> ctrl
    input  wire [`PE_COL-1:0]           In_PB_Valid,
    input  wire [`ADDR_PSRAM-1:0]       In_PB_addr,
    input  wire [`PE_COL*`BIT_PSUM-1:0] In_PB_Data,

    // sa_to_pb -> ctrl
    input  wire [`PE_COL-1:0]           In_FinishFlag
);

    localparam [BIT_OFFSET-1:0] OFFSET_RCODE   = 3'd0; // 0x00
    localparam [BIT_OFFSET-1:0] OFFSET_LOAD_W  = 3'd1; // 0x04
    localparam [BIT_OFFSET-1:0] OFFSET_LOAD_A  = 3'd2; // 0x08
    localparam [BIT_OFFSET-1:0] OFFSET_EXEC    = 3'd3; // 0x0C
    localparam [BIT_OFFSET-1:0] OFFSET_READ_PB = 3'd4; // 0x10

    localparam integer BIT_EX = BIT_INSTR - 2*BIT_ADDR;
    localparam integer BIT_COL_ID = $clog2(`PE_COL);

    integer i;

    // 0x04 / 0x08 / 0x10 : {16b address, 8b bank/column, 8b data}
    wire [BIT_CMD_ADDR-1:0] addr;
    wire [BIT_COLNUM-1:0] colnum;
    wire [`BIT_DATA-1:0] data;
    assign {addr, colnum, data} = In_Instruction;

    // 0x0C : {00,S,IC}, {01,OC,WOffset}, {10,X}
    wire [BIT_EX-1:0] execution;
    wire [BIT_ADDR-1:0] wS, wIC, wOC, wOffset;
    assign {execution, wS, wIC} = In_Instruction;
    assign wOC = wS;
    assign wOffset = wIC;

    // RCODE = {BUSY, DONE, PENDING, VALID, DATA[27:0]}
    reg BUSY, DONE, R_PENDING, R_VALID;
    reg [27:0] R_OTHER;
    assign Rcode_Out = {BUSY, DONE, R_PENDING, R_VALID, R_OTHER};

    // MatMul configuration
    reg [BIT_ADDR-1:0] S, IC, OC, Offset;

    // Execution control
    reg LD_A, WAIT_FINISH;

    // Tile counters
    reg [BIT_ADDR-1:0] cnt_S, cnt_K, cnt_OC;
    reg [`BIT_ROW_ID-1:0] cnt_row;

    // Tile base addresses
    reg [`ADDR_WSRAM-1:0] WB_Tile_Base;
    reg [`ADDR_ASRAM-1:0] AB_Tile_Base;
    reg [`ADDR_PSRAM-1:0] PB_Tile_Base;

    // Active columns
    reg [`PE_COL-1:0] Active_Col_Mask;
    reg [BIT_COL_ID-1:0] Last_Active_Col;

    always @(*) begin
        Active_Col_Mask = {`PE_COL{1'b0}};

        for (i=0; i<`PE_COL; i=i+1) begin
            if ((cnt_OC + i) < OC) Active_Col_Mask[i] = 1'b1;
        end

        if (OC <= cnt_OC) Last_Active_Col = {BIT_COL_ID{1'b0}};
        else if ((OC - cnt_OC) >= `PE_COL) Last_Active_Col = `PE_COL - 1;
        else Last_Active_Col = OC - cnt_OC - 1'b1;
    end

    wire More_OC_Tile = (cnt_OC + `PE_COL) < OC;
    wire More_K_Tile  = (cnt_K + `PE_ROW) < IC;

    // Explicit PB readback
    reg [BIT_COLNUM-1:0] Read_Col;
    wire [`BIT_PSUM-1:0] Read_PB_Data;
    wire [27:0] Read_PB_Data_28;

    assign Read_PB_Data = In_PB_Data[Read_Col*`BIT_PSUM +: `BIT_PSUM];
    assign Read_PB_Data_28 = {{(28-`BIT_PSUM){Read_PB_Data[`BIT_PSUM-1]}}, Read_PB_Data};

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

            PB_Valid_Out <= 0;
            PB_Addr_Out <= 0;
            PB_En_Tile_Out <= 0;

            {BUSY, DONE, R_PENDING, R_VALID} <= 4'b0000;
            R_OTHER <= 0;

            S <= 0;
            IC <= 0;
            OC <= 0;
            Offset <= 0;

            LD_A <= 0;
            WAIT_FINISH <= 0;

            cnt_S <= 0;
            cnt_K <= 0;
            cnt_OC <= 0;
            cnt_row <= 0;

            WB_Tile_Base <= 0;
            AB_Tile_Base <= 0;
            PB_Tile_Base <= 0;

            Read_Col <= 0;
        end
        else begin
            // pulse-type outputs
            WB_ena_Out <= 0;
            WB_wea_Out <= 0;

            AB_ena_Out <= 0;
            AB_wea_Out <= 0;

            SA_En_W_Out <= 0;
            SA_Valid_P_Out <= 0;

            PB_Valid_Out <= 0;
            PB_En_Tile_Out <= 0;

            // =====================================================
            // MatMul execution
            // =====================================================

            if (BUSY) begin

                // Final output drain
                if (WAIT_FINISH) begin
                    if (In_FinishFlag[Last_Active_Col]) begin
                        BUSY <= 1'b0;
                        DONE <= 1'b1;
                        LD_A <= 1'b0;
                        WAIT_FINISH <= 1'b0;
                    end
                end

                // Activation stream
                else if (LD_A) begin
                    if (cnt_S < S) begin
                        AB_addra_Out <= AB_Tile_Base + cnt_S;
                        AB_ena_Out <= {`PE_ROW{1'b1}};

                        SA_Addr_P_Out <= PB_Tile_Base + cnt_S;
                        SA_Valid_P_Out <= Active_Col_Mask;

                        PB_Addr_Out <= PB_Tile_Base + cnt_S;

                        if (cnt_K != 0) begin
                            PB_Valid_Out <= Active_Col_Mask;
                            PB_En_Tile_Out <= Active_Col_Mask;
                        end

                        cnt_S <= cnt_S + 1'b1;
                    end
                    else if (In_SA_Done_I[Last_Active_Col]) begin
                        cnt_S <= 0;

                        if (More_OC_Tile) begin
                            cnt_OC <= cnt_OC + `PE_COL;
                            WB_Tile_Base <= WB_Tile_Base + `PE_ROW;
                            PB_Tile_Base <= PB_Tile_Base + S;
                            cnt_row <= 0;
                            LD_A <= 1'b0;
                        end
                        else if (More_K_Tile) begin
                            cnt_K <= cnt_K + `PE_ROW;
                            cnt_OC <= 0;

                            WB_Tile_Base <= WB_Tile_Base + `PE_ROW;
                            AB_Tile_Base <= AB_Tile_Base + S;
                            PB_Tile_Base <= 0;

                            cnt_row <= 0;
                            LD_A <= 1'b0;
                        end
                        else if (In_FinishFlag[Last_Active_Col]) begin
                            BUSY <= 1'b0;
                            DONE <= 1'b1;
                            LD_A <= 1'b0;
                            WAIT_FINISH <= 1'b0;
                        end
                        else begin
                            WAIT_FINISH <= 1'b1;
                        end
                    end
                end

                // Weight load
                else begin
                    if (cnt_row < `PE_ROW) begin
                        WB_addra_Out <= WB_Tile_Base + cnt_row;
                        WB_ena_Out <= Active_Col_Mask;

                        SA_En_W_Out <= Active_Col_Mask;
                        SA_En_ID_Out <= cnt_row;

                        cnt_row <= cnt_row + 1'b1;
                    end
                    else if (In_SA_Done_W) begin
                        cnt_row <= 0;
                        cnt_S <= 0;
                        LD_A <= 1'b1;
                    end
                end
            end

            // =====================================================
            // Not executing
            // =====================================================

            else begin

                // PB response capture
                if (R_PENDING) begin
                    if (In_PB_Valid[Read_Col]) begin
                        R_OTHER <= Read_PB_Data_28;
                        R_PENDING <= 1'b0;
                        R_VALID <= 1'b1;
                    end
                end

                // New PS -> PL command
                else if (In_Valid) begin
                    case (In_Offset)

                        // 0x00 : RCODE
                        OFFSET_RCODE: begin
                        end

                        // 0x04 : Load Weight
                        OFFSET_LOAD_W: begin
                            if (colnum < `PE_COL) begin
                                WB_addra_Out <= addr[`ADDR_WSRAM-1:0];
                                WB_dina_Out <= {`PE_COL{data}};

                                WB_ena_Out <= ({{(`PE_COL-1){1'b0}},1'b1} << colnum);
                                WB_wea_Out <= ({{(`PE_COL-1){1'b0}},1'b1} << colnum);

                                DONE <= 1'b0;
                                R_PENDING <= 1'b0;
                                R_VALID <= 1'b0;
                            end
                        end

                        // 0x08 : Load Activation
                        OFFSET_LOAD_A: begin
                            if (colnum < `PE_ROW) begin
                                AB_addra_Out <= addr[`ADDR_ASRAM-1:0];
                                AB_dina_Out <= {`PE_ROW{data}};

                                AB_ena_Out <= ({{(`PE_ROW-1){1'b0}},1'b1} << colnum);
                                AB_wea_Out <= ({{(`PE_ROW-1){1'b0}},1'b1} << colnum);

                                DONE <= 1'b0;
                                R_PENDING <= 1'b0;
                                R_VALID <= 1'b0;
                            end
                        end

                        // 0x0C : Configure / Execute
                        OFFSET_EXEC: begin
                            case (execution)

                                2'b00: begin
                                    S <= wS;
                                    IC <= wIC;

                                    DONE <= 1'b0;
                                    R_PENDING <= 1'b0;
                                    R_VALID <= 1'b0;
                                end

                                2'b01: begin
                                    OC <= wOC;
                                    Offset <= wOffset;

                                    DONE <= 1'b0;
                                    R_PENDING <= 1'b0;
                                    R_VALID <= 1'b0;
                                end

                                2'b10: begin
                                    if ((S != 0) && (IC != 0) && (OC != 0)) begin
                                        BUSY <= 1'b1;
                                        DONE <= 1'b0;
                                        R_PENDING <= 1'b0;
                                        R_VALID <= 1'b0;
                                        R_OTHER <= 0;

                                        LD_A <= 1'b0;
                                        WAIT_FINISH <= 1'b0;

                                        cnt_S <= 0;
                                        cnt_K <= 0;
                                        cnt_OC <= 0;
                                        cnt_row <= 0;

                                        WB_Tile_Base <= Offset[`ADDR_WSRAM-1:0];
                                        AB_Tile_Base <= 0;
                                        PB_Tile_Base <= 0;
                                    end
                                    else begin
                                        BUSY <= 1'b0;
                                        DONE <= 1'b1;
                                        R_PENDING <= 1'b0;
                                        R_VALID <= 1'b0;
                                    end
                                end

                                default: ;
                            endcase
                        end

                        // 0x10 : Read Product Buffer
                        OFFSET_READ_PB: begin
                            if (DONE && (colnum < `PE_COL)) begin
                                PB_Addr_Out <= addr[`ADDR_PSRAM-1:0];
                                PB_Valid_Out <= ({{(`PE_COL-1){1'b0}},1'b1} << colnum);
                                PB_En_Tile_Out <= 0;

                                Read_Col <= colnum;
                                R_PENDING <= 1'b1;
                                R_VALID <= 1'b0;
                            end
                        end

                        default: ;
                    endcase
                end
            end
        end
    end

endmodule