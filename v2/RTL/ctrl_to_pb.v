`include "param.v"

module ctrl_to_pb #(
    parameter BIT_ADDR = `ADDR_PSRAM,
    parameter BIT_DATA = `BIT_PSUM,
    parameter BIT_Q = 8,
    parameter BIT_SHIFT = 5,
    parameter NB = 2
)(
    input CLK,
    input RST,

    // ctrl_to_pb
    input In_Valid,
    input [BIT_ADDR-1:0] In_Addr,
    input In_En_Tile,
    input [BIT_DATA-1:0] Bias_In,

    input In_En_Requant,
    input In_En_MaxPool,
    input [BIT_SHIFT-1:0] In_Shift,

    output [BIT_ADDR-1:0] PB_addr_Out,
    output PB_Valid_Out,
    output En_Tile_Out,
    output [BIT_DATA-1:0] Bias_Out,

    // pb_to_ctrl
    input [BIT_DATA-1:0] PB_Data_In,

    output ctrl_Valid_Out,
    output [BIT_ADDR-1:0] ctrl_addr_Out,
    output [BIT_DATA-1:0] Data_Out
);

localparam integer CTRL_W = 1 + 1 + BIT_ADDR;
localparam integer META_W = 1 + 1 + BIT_SHIFT;
localparam integer RET_W = BIT_DATA + 1 + BIT_ADDR;

localparam [BIT_DATA-1:0] QMAX = {{(BIT_DATA-BIT_Q){1'b0}}, 1'b0, {(BIT_Q-1){1'b1}}};

reg [CTRL_W*NB-1:0] ctrl_to_pb;
reg [BIT_DATA*(NB+1)-1:0] bias_to_pl;
reg [META_W*(NB+1)-1:0] post_ctrl;

reg [(1+BIT_ADDR)-1:0] midterm;

reg [BIT_DATA-1:0] requant_data;
reg requant_valid;
reg [BIT_ADDR-1:0] requant_addr;
reg requant_en_maxpool;

reg [BIT_DATA-1:0] pool_max;
reg [BIT_ADDR-1:0] pool_addr;
reg [1:0] pool_count;

reg [RET_W*NB-1:0] pb_to_ctrl;

wire En_Requant_Aligned;
wire En_MaxPool_Aligned;
wire [BIT_SHIFT-1:0] Shift_Aligned;

integer i;


/* Requantization: right shift + round + saturation to signed INT8 positive range. */
function [BIT_DATA-1:0] requant;
    input [BIT_DATA-1:0] value;
    input [BIT_SHIFT-1:0] shift;

    reg [BIT_DATA-1:0] shifted;
    reg [BIT_DATA:0] rounded;
    begin
        if (shift == 0) begin
            rounded = {1'b0, value};
        end
        else begin
            shifted = value >> shift;
            rounded = {1'b0, shifted} + value[shift-1];
        end

        if (rounded > {1'b0, QMAX})
            requant = QMAX;
        else
            requant = {{(BIT_DATA-BIT_Q){1'b0}}, rounded[BIT_Q-1:0]};
    end
endfunction


assign {En_Requant_Aligned, En_MaxPool_Aligned, Shift_Aligned} =
    post_ctrl[META_W*NB +: META_W];


always @(posedge CLK) begin
    if (RST) begin
        ctrl_to_pb <= {CTRL_W*NB{1'b0}};
        bias_to_pl <= {BIT_DATA*(NB+1){1'b0}};
        post_ctrl <= {META_W*(NB+1){1'b0}};

        midterm <= {(1+BIT_ADDR){1'b0}};

        requant_data <= {BIT_DATA{1'b0}};
        requant_valid <= 1'b0;
        requant_addr <= {BIT_ADDR{1'b0}};
        requant_en_maxpool <= 1'b0;

        pool_max <= {BIT_DATA{1'b0}};
        pool_addr <= {BIT_ADDR{1'b0}};
        pool_count <= 2'd0;

        pb_to_ctrl <= {RET_W*NB{1'b0}};
    end
    else begin
        /* Controller -> PB request pipeline */
        ctrl_to_pb[0 +: CTRL_W] <= {In_En_Tile, In_Valid, In_Addr};
        bias_to_pl[0 +: BIT_DATA] <= Bias_In;
        post_ctrl[0 +: META_W] <= {In_En_Requant, In_En_MaxPool, In_Shift};

        for (i=1; i<NB; i=i+1)
            ctrl_to_pb[CTRL_W*i +: CTRL_W] <= ctrl_to_pb[CTRL_W*(i-1) +: CTRL_W];

        for (i=1; i<NB+1; i=i+1) begin
            bias_to_pl[BIT_DATA*i +: BIT_DATA] <= bias_to_pl[BIT_DATA*(i-1) +: BIT_DATA];
            post_ctrl[META_W*i +: META_W] <= post_ctrl[META_W*(i-1) +: META_W];
        end

        /* PB read latency alignment */
        midterm <= ctrl_to_pb[CTRL_W*(NB-1) +: (1+BIT_ADDR)];

        /* Requantization register */
        requant_valid <= midterm[BIT_ADDR];
        requant_addr <= midterm[0 +: BIT_ADDR];
        requant_en_maxpool <= En_MaxPool_Aligned;

        if (En_Requant_Aligned)
            requant_data <= requant(PB_Data_In, Shift_Aligned);
        else
            requant_data <= PB_Data_In;

        /* Default: no output this cycle */
        pb_to_ctrl[0 +: RET_W] <= {{BIT_DATA{1'b0}}, 1'b0, {BIT_ADDR{1'b0}}};

        /*
         * MaxPool.
         * En_MaxPool=0 : every valid datum passes.
         * En_MaxPool=1 : four valid data -> one maximum.
         */
        if (!requant_en_maxpool) begin
            pool_count <= 2'd0;
            pool_max <= {BIT_DATA{1'b0}};

            if (requant_valid)
                pb_to_ctrl[0 +: RET_W] <= {requant_data, 1'b1, requant_addr};
        end
        else if (requant_valid) begin
            case (pool_count)
                2'd0: begin
                    pool_max <= requant_data;
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
                        pb_to_ctrl[0 +: RET_W] <= {requant_data, 1'b1, pool_addr};
                    else
                        pb_to_ctrl[0 +: RET_W] <= {pool_max, 1'b1, pool_addr};

                    pool_count <= 2'd0;
                    pool_max <= {BIT_DATA{1'b0}};
                end
            endcase
        end

        /* Existing return pipeline */
        for (i=1; i<NB; i=i+1)
            pb_to_ctrl[RET_W*i +: RET_W] <= pb_to_ctrl[RET_W*(i-1) +: RET_W];
    end
end


assign {En_Tile_Out, PB_Valid_Out, PB_addr_Out} =
    ctrl_to_pb[CTRL_W*(NB-1) +: CTRL_W];

assign Bias_Out = bias_to_pl[BIT_DATA*NB +: BIT_DATA];

assign {Data_Out, ctrl_Valid_Out, ctrl_addr_Out} =
    pb_to_ctrl[RET_W*(NB-1) +: RET_W];

endmodule