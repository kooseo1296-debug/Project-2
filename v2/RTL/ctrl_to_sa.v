`timescale 1ns / 1ps
`include "param.v"

module ctrl_to_sa #(
    parameter integer COLNUM    = 0,
    parameter integer BASE_DLY  = 5,
    parameter integer BIT_ROWID = `BIT_ROW_ID,
    parameter integer BIT_ADDR  = `ADDR_PSRAM
)(
    input  wire                     CLK,
    input  wire                     RST,

    // Controller -> SA
    input  wire                     In_En_W,
    input  wire [BIT_ROWID-1:0]     In_En_ID,
    input  wire [BIT_ADDR-1:0]      In_Addr_P,
    input  wire                     In_Valid_P,
    input  wire                     In_En_ReLU,

    // Delayed control outputs
    output wire                     En_W_Out,
    output wire [BIT_ROWID-1:0]     En_ID_Out,
    output wire [BIT_ADDR-1:0]      Addr_P_Out,
    output wire                     Valid_P_Out,
    output wire                     Out_En_ReLU,

    // Completion pulses
    output wire                     Done_W_Out,
    output wire                     Done_I_Out
);

    reg Prev_In_En_W;
    reg Prev_In_Valid_P;

    wire Done_W_In;
    wire Done_I_In;

    assign Done_W_In = Prev_In_En_W & ~In_En_W;
    assign Done_I_In = Prev_In_Valid_P & ~In_Valid_P;

    // {En_W, En_ID, Addr_P, Valid_P, En_ReLU, Done_W, Done_I}
    localparam integer CTRL_WIDTH = 1 + BIT_ROWID + BIT_ADDR + 1 + 1 + 1 + 1;

    // {Addr_P, Valid_P, En_ReLU, Done_I}
    localparam integer META_WIDTH = BIT_ADDR + 1 + 1 + 1;

    localparam integer COL_PIPE_DEPTH = (COLNUM > 0) ? COLNUM : 1;

    reg [CTRL_WIDTH*BASE_DLY-1:0] ctrl_pipe;

    wire [BIT_ADDR-1:0] Addr_P_Base;
    wire Valid_P_Base;
    wire En_ReLU_Base;
    wire Done_I_Base;

    integer i;

    always @(posedge CLK) begin
        if (RST) begin
            Prev_In_En_W <= 1'b0;
            Prev_In_Valid_P <= 1'b0;
            ctrl_pipe <= {CTRL_WIDTH*BASE_DLY{1'b0}};
        end
        else begin
            Prev_In_En_W <= In_En_W;
            Prev_In_Valid_P <= In_Valid_P;

            ctrl_pipe[0 +: CTRL_WIDTH] <= {
                In_En_W,
                In_En_ID,
                In_Addr_P,
                In_Valid_P,
                In_En_ReLU,
                Done_W_In,
                Done_I_In
            };

            for (i=1; i<BASE_DLY; i=i+1)
                ctrl_pipe[i*CTRL_WIDTH +: CTRL_WIDTH] <= ctrl_pipe[(i-1)*CTRL_WIDTH +: CTRL_WIDTH];
        end
    end

    assign {
        En_W_Out,
        En_ID_Out,
        Addr_P_Base,
        Valid_P_Base,
        En_ReLU_Base,
        Done_W_Out,
        Done_I_Base
    } = ctrl_pipe[(BASE_DLY-1)*CTRL_WIDTH +: CTRL_WIDTH];

    generate
        if (COLNUM > 0) begin : GEN_COL_DELAY
            reg [META_WIDTH*COL_PIPE_DEPTH-1:0] col_pipe;
            integer j;

            always @(posedge CLK) begin
                if (RST) begin
                    col_pipe <= {META_WIDTH*COL_PIPE_DEPTH{1'b0}};
                end
                else begin
                    col_pipe[0 +: META_WIDTH] <= {
                        Addr_P_Base,
                        Valid_P_Base,
                        En_ReLU_Base,
                        Done_I_Base
                    };

                    for (j=1; j<COLNUM; j=j+1)
                        col_pipe[j*META_WIDTH +: META_WIDTH] <= col_pipe[(j-1)*META_WIDTH +: META_WIDTH];
                end
            end

            assign {
                Addr_P_Out,
                Valid_P_Out,
                Out_En_ReLU,
                Done_I_Out
            } = col_pipe[(COLNUM-1)*META_WIDTH +: META_WIDTH];
        end

        else begin : GEN_NO_COL_DELAY
            assign {
                Addr_P_Out,
                Valid_P_Out,
                Out_En_ReLU,
                Done_I_Out
            } = {
                Addr_P_Base,
                Valid_P_Base,
                En_ReLU_Base,
                Done_I_Base
            };
        end
    endgenerate

endmodule
