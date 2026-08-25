`timescale 1ns / 1ps
`include "param.v"

module ctrl_to_pb #(
    parameter BIT_ADDR  = `ADDR_PSRAM,
    parameter BIT_DATA  = `BIT_PSUM,
    parameter NB        = 2
    )(
    input CLK,
    input RST,
    
    //ctrl_to_pb
    input In_Valid,
    input [BIT_ADDR-1:0] In_Addr,
    input In_En_Tile,

    output [BIT_ADDR-1:0] PB_addr_Out,
    output PB_Valid_Out,
    output En_Tile_Out,
    
    //pb_to_ctrl
    input [BIT_DATA-1:0] PB_Data_In,

    output ctrl_Valid_Out,
    output [BIT_ADDR-1:0] ctrl_addr_Out,
    output [BIT_DATA-1:0] Data_Out
    );
    
    reg [(1+BIT_ADDR+1)*NB-1:0] ctrl_to_pb;
    
    reg [(1+BIT_ADDR)-1:0] midterm;
    
    reg [(1+BIT_ADDR+BIT_DATA)*NB-1:0] pb_to_ctrl;
    
    integer i;
    
    always @(posedge CLK) begin
        if (RST) begin
            ctrl_to_pb <= {(1+BIT_ADDR+1)*NB{1'b0}};
            midterm <= {(1+BIT_ADDR){1'b0}};
            pb_to_ctrl <= {(1+BIT_ADDR+BIT_DATA)*NB{1'b0}};
        end
        else begin
            ctrl_to_pb[0+:(1+BIT_ADDR+1)] <= {In_En_Tile, In_Valid, In_Addr};
            midterm <= ctrl_to_pb[(1+BIT_ADDR+1)*(NB-1)+:(1+BIT_ADDR)];
            pb_to_ctrl[0+:(1+BIT_ADDR+BIT_DATA)] <= {PB_Data_In, midterm};
            
            for (i=1;i<NB;i=i+1) begin
                ctrl_to_pb[(1+BIT_ADDR+1)*i+:(1+BIT_ADDR+1)] 
                <= ctrl_to_pb[(1+BIT_ADDR+1)*(i-1)+:(1+BIT_ADDR+1)];
                pb_to_ctrl[(1+BIT_ADDR+BIT_DATA)*i+:(1+BIT_ADDR+BIT_DATA)] 
                <= pb_to_ctrl[(1+BIT_ADDR+BIT_DATA)*(i-1)+:(1+BIT_ADDR+BIT_DATA)];
            end
        end
    end
    assign {En_Tile_Out, PB_Valid_Out, PB_addr_Out} = 
    ctrl_to_pb[(1+BIT_ADDR+1)*(NB-1)+:(1+BIT_ADDR+1)];
    assign {Data_Out, ctrl_Valid_Out, ctrl_addr_Out} =
    pb_to_ctrl[(1+BIT_ADDR+BIT_DATA)*(NB-1)+:(1+BIT_ADDR+BIT_DATA)];
    
endmodule