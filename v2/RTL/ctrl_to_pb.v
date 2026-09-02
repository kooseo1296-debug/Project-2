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

    // biggest
    input In_biggest_Valid,
    input [BIT_SHIFT-1:0] In_biggest_Max_Shift
);

localparam integer BIAS_W = `PE_COL*BIT_DATA;

/*
 * Request pipeline
 *
 * stage NB-1 : PB request output
 * stage NB   : PB read metadata alignment
 */
reg [`PE_COL*(NB+1)-1:0] pipe_Valid;
reg [BIT_ADDR*(NB+1)-1:0] pipe_Addr;
reg [(NB+1)-1:0] pipe_En_Maxpool;
reg [(NB+1)-1:0] pipe_En_Requant;

reg [`PE_COL*NB-1:0] pipe_En_Tile;
reg [BIAS_W*NB-1:0] pipe_Bias;

/* biggest result */
reg [BIT_SHIFT-1:0] Max_Shift;

/* Requant register */
reg [BIT_DATA-1:0] requant_data;
reg [`PE_COL-1:0] requant_valid;
reg [BIT_ADDR-1:0] requant_addr;
reg requant_en_maxpool;

/* MaxPool state */
reg [BIT_DATA-1:0] pool_max;
reg [`PE_COL-1:0] pool_valid;
reg [BIT_ADDR-1:0] pool_addr;
reg [1:0] pool_count;

/* Final output register */
reg [BIT_DATA-1:0] ctrl_data_reg;
reg [`PE_COL-1:0] ctrl_valid_reg;
reg [BIT_ADDR-1:0] ctrl_addr_reg;

wire [`PE_COL-1:0] Read_Valid;
wire [BIT_ADDR-1:0] Read_Addr;
wire Read_En_Maxpool;
wire Read_En_Requant;

wire [BIT_DATA-1:0] Selected_PB_Data;
wire [BIT_SHIFT-1:0] Shift_Use;

integer i;


/* One-hot PB bank selection */
function [BIT_DATA-1:0] select_pb_data;
    input [`PE_COL*BIT_DATA-1:0] data;
    input [`PE_COL-1:0] valid;
    integer k;
    begin
        select_pb_data = {BIT_DATA{1'b0}};
        for (k=0; k<`PE_COL; k=k+1)
            if (valid[k]) select_pb_data = data[k*BIT_DATA +: BIT_DATA];
    end
endfunction


/* ReLU output requantization: shift + round + saturation */
function [BIT_DATA-1:0] requant;
    input [BIT_DATA-1:0] value;
    input [BIT_SHIFT-1:0] shift;

    reg [BIT_DATA-1:0] shifted;
    reg round_bit;
    reg [BIT_DATA:0] rounded;

    begin
        if (value[BIT_DATA-1]) begin
            requant = {BIT_DATA{1'b0}};
        end
        else begin
            if (shift == 0) begin
                shifted = value;
                round_bit = 1'b0;
            end
            else begin
                shifted = value >> shift;
                round_bit = value[shift-1];
            end

            rounded = {1'b0, shifted} + round_bit;

            if (rounded > 127)
                requant = 127;
            else
                requant = rounded[BIT_DATA-1:0];
        end
    end
endfunction


assign PB_Valid_Out = pipe_Valid[`PE_COL*(NB-1) +: `PE_COL];
assign PB_Addr_Out = pipe_Addr[BIT_ADDR*(NB-1) +: BIT_ADDR];
assign En_Tile_Out = pipe_En_Tile[`PE_COL*(NB-1) +: `PE_COL];
assign Bias_Out = pipe_Bias[BIAS_W*(NB-1) +: BIAS_W];

/* PB read latency before metadata */
assign Read_Valid = pipe_Valid[`PE_COL*NB +: `PE_COL];
assign Read_Addr = pipe_Addr[BIT_ADDR*NB +: BIT_ADDR];
assign Read_En_Maxpool = pipe_En_Maxpool[NB];
assign Read_En_Requant = pipe_En_Requant[NB];

assign Selected_PB_Data = select_pb_data(PB_Data_In, Read_Valid);

/*
 * make sure to use new shift for requantization
 * when biggest_valid goes high with requant at the same cycle
 */
 
assign Shift_Use = In_biggest_Valid ? In_biggest_Max_Shift : Max_Shift;

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
        /* biggest -> shift register */
        if (In_biggest_Valid)
            Max_Shift <= In_biggest_Max_Shift;

        /* Ctrl -> PB pipeline */
        pipe_Valid[0 +: `PE_COL] <= In_Valid;
        pipe_Addr[0 +: BIT_ADDR] <= In_Addr;
        pipe_En_Maxpool[0] <= In_En_Maxpool;
        pipe_En_Requant[0] <= In_En_Requant;

        pipe_En_Tile[0 +: `PE_COL] <= In_En_Tile;
        pipe_Bias[0 +: BIAS_W] <= Bias_In;

        for (i=1; i<NB+1; i=i+1) begin
            pipe_Valid[`PE_COL*i +: `PE_COL] <= pipe_Valid[`PE_COL*(i-1) +: `PE_COL];
            pipe_Addr[BIT_ADDR*i +: BIT_ADDR] <= pipe_Addr[BIT_ADDR*(i-1) +: BIT_ADDR];
            pipe_En_Maxpool[i] <= pipe_En_Maxpool[i-1];
            pipe_En_Requant[i] <= pipe_En_Requant[i-1];
        end

        for (i=1; i<NB; i=i+1) begin
            pipe_En_Tile[`PE_COL*i +: `PE_COL] <= pipe_En_Tile[`PE_COL*(i-1) +: `PE_COL];
            pipe_Bias[BIAS_W*i +: BIAS_W] <= pipe_Bias[BIAS_W*(i-1) +: BIAS_W];
        end

        /*
         * PB read -> requant
         *
         * Read_Valid/Addr/Enable은 PB_Data_In과 timing 정렬됨.
         * PB에서는 한 번에 한 column만 read한다는 one-hot 가정.
         */
        requant_valid <= Read_Valid;
        requant_addr <= Read_Addr;
        requant_en_maxpool <= Read_En_Maxpool;

        if (Read_En_Requant)
            requant_data <= requant(Selected_PB_Data, Shift_Use);
        else
            requant_data <= Selected_PB_Data;

        /*
         * Requant -> optional MaxPool
         *
         * 기본적으로 ctrl valid는 0.
         * MaxPool OFF : valid 하나당 바로 output.
         * MaxPool ON  : valid 4개 중 네 번째에서만 output.
         */
        ctrl_valid_reg <= {`PE_COL{1'b0}};

        if (|requant_valid) begin
            if (!requant_en_maxpool) begin
                ctrl_data_reg <= requant_data;
                ctrl_addr_reg <= requant_addr;
                ctrl_valid_reg <= requant_valid;

                pool_count <= 2'd0;
                pool_max <= {BIT_DATA{1'b0}};
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

                        pool_count <= 2'd0;
                        pool_max <= {BIT_DATA{1'b0}};
                    end
                endcase
            end
        end
    end
end

endmodule