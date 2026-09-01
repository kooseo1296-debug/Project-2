`include "param.v"

module InputLoader (
    input CLK,
    input  [`PE_ROW*`BIT_DATA-1:0] i_Data_I_In,
    output [`PE_ROW*`BIT_DATA-1:0] o_Data_I_In
);
    localparam NumberofBuffers = 1;
    wire [`PE_ROW*`BIT_DATA-1:0] Wireline;
    reg [`PE_ROW*`BIT_DATA*NumberofBuffers-1:0] Buffer;
    
    genvar i, j;
    generate
        for (i = 0; i < `PE_ROW; i = i + 1) begin : Delay_Row
            reg [`BIT_DATA-1:0] delay_regs [i:0];

            always @(posedge CLK) begin
                delay_regs[i] <= i_Data_I_In[i*`BIT_DATA +: `BIT_DATA];
            end

            if (i > 0) begin
                for (j = 0; j < i; j = j + 1) begin : Shift
                    always @(posedge CLK) begin
                        delay_regs[j] <= delay_regs[j+1];
                    end
                end
            end

            assign Wireline[i*`BIT_DATA +: `BIT_DATA] = delay_regs[0];
        end
    endgenerate
    
    always @(posedge CLK) Buffer[0+:`PE_ROW*`BIT_DATA] <= Wireline;
    
    for (i=1;i<NumberofBuffers; i=i+1) begin
        always @(posedge CLK) Buffer[i*`PE_ROW*`BIT_DATA+:`PE_ROW*`BIT_DATA] <= Buffer[(i-1)*`PE_ROW*`BIT_DATA+:`PE_ROW*`BIT_DATA];
    end
    
    assign o_Data_I_In = Buffer[`PE_ROW*`BIT_DATA*NumberofBuffers-1:`PE_ROW*`BIT_DATA*(NumberofBuffers-1)];
    
endmodule