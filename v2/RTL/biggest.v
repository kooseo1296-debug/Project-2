`include "param.v"

module biggest #(
    parameter integer PE_COL  = `PE_COL,
    parameter integer BIT_MSB = 5,
    parameter integer BIT_CNT = 8
)(
    input  wire                      CLK,
    input  wire                      RST,
    input  wire [BIT_CNT-1:0]        In_Count,
    input  wire [PE_COL-1:0]         In_Valid,
    input  wire [PE_COL*BIT_MSB-1:0] In_MSB,

    output reg  [BIT_MSB-1:0]        Max_MSB_Out,
    output reg                       Valid_Out
);

    reg [BIT_CNT-1:0] cnt;
    reg [BIT_MSB-1:0] max_msb;

    integer i;

    always @(posedge CLK) begin
        if (RST) begin
            cnt <= {BIT_CNT{1'b0}};
            max_msb <= {BIT_MSB{1'b0}};
            Max_MSB_Out <= {BIT_MSB{1'b0}};
            Valid_Out <= 1'b0;
        end
        else begin
            Valid_Out <= 1'b0;

            if (In_Count != {BIT_CNT{1'b0}}) begin
                cnt <= In_Count;
                max_msb <= {BIT_MSB{1'b0}};
            end
            else begin
                for (i=0; i<PE_COL; i=i+1) begin
                    if (In_Valid[i]) begin
                        if (cnt == 1) begin
                            cnt <= {BIT_CNT{1'b0}};
                            Max_MSB_Out <= (In_MSB[i*BIT_MSB +: BIT_MSB] > max_msb) ?
                                           In_MSB[i*BIT_MSB +: BIT_MSB] : max_msb;
                            max_msb <= {BIT_MSB{1'b0}};
                            Valid_Out <= 1'b1;
                        end
                        else begin
                            cnt <= cnt - 1'b1;
                            if (In_MSB[i*BIT_MSB +: BIT_MSB] > max_msb)
                                max_msb <= In_MSB[i*BIT_MSB +: BIT_MSB];
                        end
                    end
                end
            end
        end
    end

endmodule
