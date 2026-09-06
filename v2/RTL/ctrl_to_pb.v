`timescale 1ns / 1ps
`include "param.v"

module ctrl_to_pb #(
    parameter BIT_ADDR  = `ADDR_PSRAM,
    parameter BIT_DATA  = `BIT_PSUM,
    parameter NB        = 2,
    parameter BIT_SHIFT = 5
)(
    input CLK,
    input RST,

    // Ctrl -> PB
    input [`PE_COL-1:0] In_Valid,
    input [BIT_ADDR-1:0] In_Addr,
    input [`PE_COL-1:0] In_En_Tile,
    input In_En_Maxpool,
    input In_En_Requant,

    // Ctrl -> ProductLoader
    input [`PE_COL*BIT_DATA-1:0] Bias_In,

    output [BIT_ADDR-1:0] PB_Addr_Out,
    output [`PE_COL-1:0] PB_Valid_Out,
    output [`PE_COL-1:0] En_Tile_Out,
    output [`PE_COL*BIT_DATA-1:0] Bias_Out,

    // PB -> ctrl_to_pb
    input [`PE_COL*BIT_DATA-1:0] PB_Data_In,

    // ctrl_to_pb -> Ctrl
    output [`PE_COL-1:0] ctrl_Valid_Out,
    output [BIT_ADDR-1:0] ctrl_Addr_Out,
    output [BIT_DATA-1:0] Data_Out,

    // biggest -> ctrl_to_pb
    input In_biggest_Valid,
    input [BIT_SHIFT-1:0] In_biggest_Max_Shift
);

localparam integer BIAS_W = `PE_COL*BIT_DATA;

/*
 * Request pipeline.
 *
 * Stage NB-1 sends the request to PB.
 * Stage NB aligns the request metadata with the synchronous PB read result.
 */
reg [`PE_COL*(NB+1)-1:0] pipe_Valid;
reg [BIT_ADDR*(NB+1)-1:0] pipe_Addr;
reg [(NB+1)-1:0] pipe_En_Maxpool;
reg [(NB+1)-1:0] pipe_En_Requant;

/*
 * En_Tile and Bias stop at the PB-request stage.
 * ProductLoader adds one internal cycle for PB read alignment.
 */
reg [`PE_COL*NB-1:0] pipe_En_Tile;
reg [BIAS_W*NB-1:0] pipe_Bias;

/* Requantization shift register */
reg [BIT_SHIFT-1:0] Max_Shift;

/*
 * PB bank-selection pipeline stage.
 *
 * This register separates:
 *   PB BRAM -> bank select
 * from:
 *   variable shift -> rounding -> saturation
 */
reg [BIT_DATA-1:0] selected_data_reg;
reg [`PE_COL-1:0] selected_valid_reg;
reg [BIT_ADDR-1:0] selected_addr_reg;
reg selected_en_requant_reg;
reg selected_en_maxpool_reg;

/* Requantization output registers */
reg [BIT_DATA-1:0] requant_data;
reg [`PE_COL-1:0] requant_valid;
reg [BIT_ADDR-1:0] requant_addr;
reg requant_en_maxpool;

/* MaxPool state */
reg [BIT_DATA-1:0] pool_max;
reg [`PE_COL-1:0] pool_valid;
reg [BIT_ADDR-1:0] pool_addr;
reg [1:0] pool_count;

/* Final Ctrl output registers */
reg [BIT_DATA-1:0] ctrl_data_reg;
reg [`PE_COL-1:0] ctrl_valid_reg;
reg [BIT_ADDR-1:0] ctrl_addr_reg;

/* Metadata aligned with PB_Data_In */
wire [`PE_COL-1:0] Read_Valid;
wire [BIT_ADDR-1:0] Read_Addr;
wire Read_En_Maxpool;
wire Read_En_Requant;

/* Selected PB read data */
wire [BIT_DATA-1:0] Selected_PB_Data;

integer i;


/*
 * Select one PB bank.
 *
 * Read_Valid is guaranteed to be one-hot-or-zero.
 * A masked OR is used instead of a priority selection.
 */
function [BIT_DATA-1:0] Select_PB_Data;
    input [`PE_COL*BIT_DATA-1:0] Data;
    input [`PE_COL-1:0] Valid;
    integer k;
    begin
        Select_PB_Data = {BIT_DATA{1'b0}};
        for (k=0; k<`PE_COL; k=k+1)
            Select_PB_Data =
                Select_PB_Data |
                (Data[k*BIT_DATA +: BIT_DATA] & {BIT_DATA{Valid[k]}});
    end
endfunction


/*
 * Requantization for non-negative post-ReLU data.
 *
 *   shifted = value >> shift
 *   rounded = shifted + rounding_bit
 *   output  = min(rounded, 127)
 */
function [BIT_DATA-1:0] Requant;
    input [BIT_DATA-1:0] Value;
    input [BIT_SHIFT-1:0] Shift;

    reg [BIT_DATA-1:0] shifted;
    reg round_bit;
    reg [BIT_DATA:0] rounded;

    begin
        if (Value[BIT_DATA-1]) begin
            Requant = {BIT_DATA{1'b0}};
        end
        else begin
            if (Shift == 0) begin
                shifted = Value;
                round_bit = 1'b0;
            end
            else begin
                shifted = Value >> Shift;
                round_bit = Value[Shift-1];
            end

            rounded = {1'b0, shifted} + round_bit;

            if (rounded > 127)
                Requant = 127;
            else
                Requant = rounded[BIT_DATA-1:0];
        end
    end
endfunction


/* PB request outputs */
assign PB_Valid_Out = pipe_Valid[`PE_COL*(NB-1) +: `PE_COL];
assign PB_Addr_Out = pipe_Addr[BIT_ADDR*(NB-1) +: BIT_ADDR];

/* ProductLoader outputs */
assign En_Tile_Out = pipe_En_Tile[`PE_COL*(NB-1) +: `PE_COL];
assign Bias_Out = pipe_Bias[BIAS_W*(NB-1) +: BIAS_W];

/* Metadata aligned with the synchronous PB read result */
assign Read_Valid = pipe_Valid[`PE_COL*NB +: `PE_COL];
assign Read_Addr = pipe_Addr[BIT_ADDR*NB +: BIT_ADDR];
assign Read_En_Maxpool = pipe_En_Maxpool[NB];
assign Read_En_Requant = pipe_En_Requant[NB];

assign Selected_PB_Data = Select_PB_Data(PB_Data_In, Read_Valid);

/* Final outputs */
assign ctrl_Valid_Out = ctrl_valid_reg;
assign ctrl_Addr_Out = ctrl_addr_reg;
assign Data_Out = ctrl_data_reg;


always @(posedge CLK) begin
    if (RST) begin
        pipe_Valid <= {(`PE_COL*(NB+1)){1'b0}};
        pipe_Addr <= {(BIT_ADDR*(NB+1)){1'b0}};
        pipe_En_Maxpool <= {(NB+1){1'b0}};
        pipe_En_Requant <= {(NB+1){1'b0}};

        pipe_En_Tile <= {(`PE_COL*NB){1'b0}};
        pipe_Bias <= {(BIAS_W*NB){1'b0}};

        Max_Shift <= {BIT_SHIFT{1'b0}};

        selected_data_reg <= {BIT_DATA{1'b0}};
        selected_valid_reg <= {`PE_COL{1'b0}};
        selected_addr_reg <= {BIT_ADDR{1'b0}};
        selected_en_requant_reg <= 1'b0;
        selected_en_maxpool_reg <= 1'b0;

        requant_data <= {BIT_DATA{1'b0}};
        requant_valid <= {`PE_COL{1'b0}};
        requant_addr <= {BIT_ADDR{1'b0}};
        requant_en_maxpool <= 1'b0;

        pool_max <= {BIT_DATA{1'b0}};
        pool_valid <= {`PE_COL{1'b0}};
        pool_addr <= {BIT_ADDR{1'b0}};
        pool_count <= 2'd0;

        ctrl_data_reg <= {BIT_DATA{1'b0}};
        ctrl_valid_reg <= {`PE_COL{1'b0}};
        ctrl_addr_reg <= {BIT_ADDR{1'b0}};
    end
    else begin
        /*
         * Capture a new layer requantization shift.
         */
        if (In_biggest_Valid)
            Max_Shift <= In_biggest_Max_Shift;

        /* Ctrl -> PB request pipeline */
        pipe_Valid[0 +: `PE_COL] <= In_Valid;
        pipe_Addr[0 +: BIT_ADDR] <= In_Addr;
        pipe_En_Maxpool[0] <= In_En_Maxpool;
        pipe_En_Requant[0] <= In_En_Requant;

        /* Ctrl -> ProductLoader pipeline */
        pipe_En_Tile[0 +: `PE_COL] <= In_En_Tile;
        pipe_Bias[0 +: BIAS_W] <= Bias_In;

        for (i=1; i<NB+1; i=i+1) begin
            pipe_Valid[`PE_COL*i +: `PE_COL]
                <= pipe_Valid[`PE_COL*(i-1) +: `PE_COL];

            pipe_Addr[BIT_ADDR*i +: BIT_ADDR]
                <= pipe_Addr[BIT_ADDR*(i-1) +: BIT_ADDR];

            pipe_En_Maxpool[i] <= pipe_En_Maxpool[i-1];
            pipe_En_Requant[i] <= pipe_En_Requant[i-1];
        end

        for (i=1; i<NB; i=i+1) begin
            pipe_En_Tile[`PE_COL*i +: `PE_COL]
                <= pipe_En_Tile[`PE_COL*(i-1) +: `PE_COL];

            pipe_Bias[BIAS_W*i +: BIAS_W]
                <= pipe_Bias[BIAS_W*(i-1) +: BIAS_W];
        end

        /*
         * Stage 1 of the PB-to-Ctrl path:
         * register the selected PB bank and all associated metadata.
         */
        selected_data_reg <= Selected_PB_Data;
        selected_valid_reg <= Read_Valid;
        selected_addr_reg <= Read_Addr;
        selected_en_requant_reg <= Read_En_Requant;
        selected_en_maxpool_reg <= Read_En_Maxpool;

        /*
         * Stage 2 of the PB-to-Ctrl path:
         * perform requantization after the bank-selection register.
         */
        requant_valid <= selected_valid_reg;
        requant_addr <= selected_addr_reg;
        requant_en_maxpool <= selected_en_maxpool_reg;

        if (selected_en_requant_reg)
            requant_data <= Requant(selected_data_reg, Max_Shift);
        else
            requant_data <= selected_data_reg;

        /*
         * Stage 3 of the PB-to-Ctrl path:
         * optional MaxPool and final Ctrl output register.
         *
         * MaxPool disabled:
         *   one valid input produces one valid output.
         *
         * MaxPool enabled:
         *   four valid inputs produce one maximum value.
         *   ctrl_Valid_Out is asserted only for the fourth input.
         */
        ctrl_valid_reg <= {`PE_COL{1'b0}};

        if (|requant_valid) begin
            if (!requant_en_maxpool) begin
                ctrl_data_reg <= requant_data;
                ctrl_addr_reg <= requant_addr;
                ctrl_valid_reg <= requant_valid;

                pool_max <= {BIT_DATA{1'b0}};
                pool_valid <= {`PE_COL{1'b0}};
                pool_addr <= {BIT_ADDR{1'b0}};
                pool_count <= 2'd0;
            end
            else begin
                case (pool_count)
                    2'd0: begin
                        pool_max <= requant_data;
                        pool_valid <= requant_valid;
                        pool_addr <= requant_addr;
                        pool_count <= 2'd1;
                    end

                    2'd1: begin
                        if (requant_data > pool_max)
                            pool_max <= requant_data;

                        pool_count <= 2'd2;
                    end

                    2'd2: begin
                        if (requant_data > pool_max)
                            pool_max <= requant_data;

                        pool_count <= 2'd3;
                    end

                    2'd3: begin
                        if (requant_data > pool_max)
                            ctrl_data_reg <= requant_data;
                        else
                            ctrl_data_reg <= pool_max;

                        ctrl_addr_reg <= pool_addr;
                        ctrl_valid_reg <= pool_valid;

                        pool_max <= {BIT_DATA{1'b0}};
                        pool_valid <= {`PE_COL{1'b0}};
                        pool_addr <= {BIT_ADDR{1'b0}};
                        pool_count <= 2'd0;
                    end
                endcase
            end
        end
    end
end

endmodule