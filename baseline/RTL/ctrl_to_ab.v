`include "param.v"

module ctrl_to_ab#(
    parameter NB = 2,
    parameter BITWIDTH = (`ADDR_ASRAM + `BIT_DATA + 2)
    )(
    input CLK, RST,
    input [`ADDR_ASRAM-1:0] In_addra,
    input [`BIT_DATA-1:0] In_dina,
    input In_ena, In_wea,
    
    output [`ADDR_ASRAM-1:0] addra_Out,
    output [`BIT_DATA-1:0] dina_Out,
    output ena_Out, wea_Out
    );
    
    reg [BITWIDTH*NB-1:0] Buffer;
    
    always @(posedge CLK) begin
        if (RST) Buffer[0+:BITWIDTH] <= {BITWIDTH{1'b0}};
        else Buffer[0+:BITWIDTH] <= {In_addra, In_dina, In_ena, In_wea};
    end 
    genvar i;
    for (i=1;i<NB;i=i+1) begin
        always @(posedge CLK) begin
            if (RST) Buffer[BITWIDTH*i+:BITWIDTH] <= {BITWIDTH{1'b0}};
            else Buffer[BITWIDTH*i+:BITWIDTH] <= Buffer[BITWIDTH*(i-1)+:BITWIDTH];
        end
    end
    
    assign {addra_Out, dina_Out, ena_Out, wea_Out} = Buffer[BITWIDTH*(NB-1)+:BITWIDTH];
    
endmodule