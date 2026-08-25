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

    // Delayed control outputs
    output wire                     En_W_Out,
    output wire [BIT_ROWID-1:0]     En_ID_Out,
    output wire [BIT_ADDR-1:0]      Addr_P_Out,
    output wire                     Valid_P_Out,

    // Completion pulses
    output wire                     Done_W_Out,
    output wire                     Done_I_Out
);

    // ============================================================
    // Falling-edge detection at controller input
    //
    // The generated Done pulses are inserted into the same
    // pipeline as their corresponding control signals.
    // Therefore Done becomes HIGH in the same output cycle
    // that En_W / Valid_P becomes LOW.
    // ============================================================

    reg Prev_In_En_W;
    reg Prev_In_Valid_P;

    wire Done_W_In;
    wire Done_I_In;

    assign Done_W_In =
        Prev_In_En_W & ~In_En_W;

    assign Done_I_In =
        Prev_In_Valid_P & ~In_Valid_P;


    // ============================================================
    // Local Parameters
    // ============================================================

    // Base packet:
    //
    // {
    //     En_W,
    //     En_ID,
    //     Addr_P,
    //     Valid_P,
    //     Done_W,
    //     Done_I
    // }
    localparam integer CTRL_WIDTH =
        1 + BIT_ROWID + BIT_ADDR + 1 + 1 + 1;


    // Column-dependent packet:
    //
    // {
    //     Addr_P,
    //     Valid_P,
    //     Done_I
    // }
    localparam integer META_WIDTH =
        BIT_ADDR + 1 + 1;


    // Avoid zero-width declaration when COLNUM == 0
    localparam integer COL_PIPE_DEPTH =
        (COLNUM > 0) ? COLNUM : 1;


    // ============================================================
    // Base Controller -> SA Pipeline
    //
    // Delay:
    //
    //     BASE_DLY clocks
    //
    // En_W
    // En_ID
    // Addr_P
    // Valid_P
    // Done_W
    // Done_I
    //
    // are all initially aligned here.
    // ============================================================

    reg [CTRL_WIDTH*BASE_DLY-1:0] ctrl_pipe;

    wire [BIT_ADDR-1:0] Addr_P_Base;
    wire                Valid_P_Base;
    wire                Done_I_Base;

    integer i;


    always @(posedge CLK) begin
        if (RST) begin

            Prev_In_En_W   <= 1'b0;
            Prev_In_Valid_P <= 1'b0;

            ctrl_pipe <= {CTRL_WIDTH*BASE_DLY{1'b0}};

        end
        else begin

            // ----------------------------------------------------
            // Store current controller state for next-cycle
            // falling-edge detection
            // ----------------------------------------------------

            Prev_In_En_W <= In_En_W;

            Prev_In_Valid_P <= In_Valid_P;


            // ----------------------------------------------------
            // Insert new control packet
            // ----------------------------------------------------

            ctrl_pipe[0 +: CTRL_WIDTH]
                <= {In_En_W, In_En_ID, In_Addr_P, 
                In_Valid_P, Done_W_In, Done_I_In };


            // ----------------------------------------------------
            // Shift base pipeline
            // ----------------------------------------------------

            for (i = 1;i < BASE_DLY;i = i + 1) begin
                ctrl_pipe[
                    i*CTRL_WIDTH
                    +: CTRL_WIDTH
                ] <=
                ctrl_pipe[
                    (i-1)*CTRL_WIDTH
                    +: CTRL_WIDTH
                ];
            end
        end
    end

    // ============================================================
    // Base Pipeline Output
    //
    // Done_W_Out ends here because En_W has no column-dependent
    // skew.
    //
    // Done_I_Base continues into the column-dependent pipeline
    // together with Addr_P / Valid_P.
    // ============================================================

    assign {
        En_W_Out,
        En_ID_Out,
        Addr_P_Base,
        Valid_P_Base,
        Done_W_Out,
        Done_I_Base
    } =
        ctrl_pipe[
            (BASE_DLY-1)*CTRL_WIDTH
            +: CTRL_WIDTH
        ];


    // ============================================================
    // Column-dependent Product Metadata Pipeline
    //
    // Addr_P
    // Valid_P
    // Done_I
    //
    // receive COLNUM additional clocks.
    //
    // Total delay:
    //
    //     BASE_DLY + COLNUM
    //
    // Done_I therefore remains aligned with the falling edge
    // of Valid_P_Out.
    // ============================================================

    generate

        if (COLNUM > 0) begin : GEN_COL_DELAY

            reg [META_WIDTH*COL_PIPE_DEPTH-1:0]
                col_pipe;

            integer j;

            always @(posedge CLK) begin
                if (RST) begin
                    col_pipe
                        <= {
                            META_WIDTH*COL_PIPE_DEPTH
                            {1'b0}
                        };
                end
                else begin

                    // --------------------------------------------
                    // Insert base-delayed metadata
                    // --------------------------------------------

                    col_pipe[0 +: META_WIDTH]
                        <= {
                            Addr_P_Base,
                            Valid_P_Base,
                            Done_I_Base
                        };

                    // --------------------------------------------
                    // Column-dependent shift
                    // --------------------------------------------

                    for (
                        j = 1;
                        j < COLNUM;
                        j = j + 1
                    ) begin
                        col_pipe[
                            j*META_WIDTH
                            +: META_WIDTH
                        ]
                            <=
                        col_pipe[
                            (j-1)*META_WIDTH
                            +: META_WIDTH
                        ];
                    end
                end
            end

            assign {
                Addr_P_Out,
                Valid_P_Out,
                Done_I_Out
            } =
                col_pipe[
                    (COLNUM-1)*META_WIDTH
                    +: META_WIDTH
                ];
        end

        // ========================================================
        // Column 0:
        // no additional skew
        // ========================================================

        else begin : GEN_NO_COL_DELAY

            assign {
                Addr_P_Out,
                Valid_P_Out,
                Done_I_Out
            } = {
                Addr_P_Base,
                Valid_P_Base,
                Done_I_Base
            };
        end
    endgenerate

endmodule