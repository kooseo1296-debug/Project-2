`timescale 1ns / 1ps
`include "param.v"

module biggest #(
    parameter integer PE_COL    = `PE_COL,
    parameter integer BIT_MSB   = 5,
    parameter integer BIT_CNT   = 8,
    parameter integer BIT_SHIFT = 5
)(
    input wire CLK,
    input wire RST,

    // Ctrl -> biggest
    input wire [BIT_CNT-1:0] In_Count,

    // sa_to_pb -> biggest
    input wire [PE_COL-1:0] In_Valid,
    input wire [PE_COL*BIT_MSB-1:0] In_MSB,

    // biggest -> ctrl_to_pb
    output reg [BIT_SHIFT-1:0] PB_Max_Shift_Out,
    output reg Valid_PB_Out,

    // biggest -> Ctrl
    output reg [BIT_SHIFT-1:0] Ctrl_Max_Shift_Out,
    output reg Valid_Ctrl_Out
);

localparam [BIT_MSB-1:0] TARGET_MSB = 6;

/*
 * Input pipeline stage.
 * Max_MSB and Max_Valid from sa_to_pb are captured together.
 */
reg [PE_COL-1:0] valid_in_reg;
reg [PE_COL*BIT_MSB-1:0] msb_in_reg;

/* Layer-global accumulation state */
reg [BIT_CNT-1:0] cnt;
reg [BIT_MSB-1:0] max_msb;

wire any_valid;
wire [BIT_MSB-1:0] current_msb;
wire [BIT_MSB-1:0] final_msb;
wire [BIT_SHIFT-1:0] final_shift;


/*
 * Select the MSB corresponding to the valid physical column.
 *
 * valid_in_reg is guaranteed to be one-hot-or-zero.
 * Therefore an OR-based selection is sufficient.
 */
function [BIT_MSB-1:0] Select_MSB;
    input [PE_COL*BIT_MSB-1:0] Data;
    input [PE_COL-1:0] Valid;
    integer i;
    begin
        Select_MSB = {BIT_MSB{1'b0}};

        for (i=0; i<PE_COL; i=i+1)
            Select_MSB =
                Select_MSB |
                (Data[i*BIT_MSB +: BIT_MSB] & {BIT_MSB{Valid[i]}});
    end
endfunction


assign any_valid = |valid_in_reg;
assign current_msb = Select_MSB(msb_in_reg, valid_in_reg);

assign final_msb =
    (current_msb > max_msb) ? current_msb : max_msb;

/*
 * Signed INT8 positive range is 0~127.
 * MSB index 6 or less requires no right shift.
 */
assign final_shift =
    (final_msb > TARGET_MSB) ?
    final_msb - TARGET_MSB :
    {BIT_SHIFT{1'b0}};


always @(posedge CLK) begin
    if (RST) begin
        valid_in_reg <= {PE_COL{1'b0}};
        msb_in_reg <= {(PE_COL*BIT_MSB){1'b0}};

        cnt <= {BIT_CNT{1'b0}};
        max_msb <= {BIT_MSB{1'b0}};

        PB_Max_Shift_Out <= {BIT_SHIFT{1'b0}};
        Ctrl_Max_Shift_Out <= {BIT_SHIFT{1'b0}};
        Valid_PB_Out <= 1'b0;
        Valid_Ctrl_Out <= 1'b0;
    end
    else begin
        /*
         * Stage 1:
         * Register local Max_MSB and Max_Valid from sa_to_pb.
         */
        valid_in_reg <= In_Valid;
        msb_in_reg <= In_MSB;

        /*
         * Stage 2 output valid signals are one-cycle pulses.
         * Separate output registers are used for Ctrl and ctrl_to_pb.
         */
        Valid_PB_Out <= 1'b0;
        Valid_Ctrl_Out <= 1'b0;

        /*
         * Load the number of local-max results expected for this layer.
         * In_Count must be non-zero for only one cycle.
         */
        if (In_Count != {BIT_CNT{1'b0}}) begin
            cnt <= In_Count;
            max_msb <= {BIT_MSB{1'b0}};
        end
        else if (any_valid && (cnt != {BIT_CNT{1'b0}})) begin

            /*
             * The last expected local-max result produces the
             * registered layer-global shift.
             */
            if (cnt == 1) begin
                cnt <= {BIT_CNT{1'b0}};
                max_msb <= {BIT_MSB{1'b0}};

                PB_Max_Shift_Out <= final_shift;
                Ctrl_Max_Shift_Out <= final_shift;

                Valid_PB_Out <= 1'b1;
                Valid_Ctrl_Out <= 1'b1;
            end
            else begin
                cnt <= cnt - 1'b1;

                if (current_msb > max_msb)
                    max_msb <= current_msb;
            end
        end
    end
end

endmodule