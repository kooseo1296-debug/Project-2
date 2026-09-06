`timescale 1 ns / 1 ps

module myip_slave_lite_v1_0_S00_AXI #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 5
)(
    // Global
    input  wire                                      S_AXI_ACLK,
    input  wire                                      S_AXI_ARESETN,

    // Write address
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]             S_AXI_AWADDR,
    input  wire [2:0]                                S_AXI_AWPROT,
    input  wire                                      S_AXI_AWVALID,
    output wire                                      S_AXI_AWREADY,

    // Write data
    input  wire [C_S_AXI_DATA_WIDTH-1:0]             S_AXI_WDATA,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0]         S_AXI_WSTRB,
    input  wire                                      S_AXI_WVALID,
    output wire                                      S_AXI_WREADY,

    // Write response
    output wire [1:0]                                S_AXI_BRESP,
    output wire                                      S_AXI_BVALID,
    input  wire                                      S_AXI_BREADY,

    // Read address
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]             S_AXI_ARADDR,
    input  wire [2:0]                                S_AXI_ARPROT,
    input  wire                                      S_AXI_ARVALID,
    output wire                                      S_AXI_ARREADY,

    // Read data
    output wire [C_S_AXI_DATA_WIDTH-1:0]             S_AXI_RDATA,
    output wire [1:0]                                S_AXI_RRESP,
    output wire                                      S_AXI_RVALID,
    input  wire                                      S_AXI_RREADY
);

    localparam integer ADDR_LSB = 2;

    // =====================================================================
    // V2 register map
    //
    // 0x00 READ  : RCODE = {BUSY, DONE, Class[3:0], Value[25:0]}
    // 0x04 WRITE : Weight     {Address[15:0], Column[7:0], Data[7:0]}
    // 0x08 WRITE : Activation {Address[15:0], Color [7:0], Data[7:0]}
    // 0x0C WRITE : Bias
    //              header : {1'b0, Layer[6:0], BiasNum[23:0]}
    //              value  : {1'b1, BiasValue[30:0]}
    //
    // There is no V1 CONFIG/EXECUTE/READ_PB register in V2.
    // The first R-channel activation starts inference automatically.
    // =====================================================================

    // =====================================================================
    // AXI write buffering
    // AW and W are independent AXI4-Lite channels, so capture them
    // separately and generate one MatMul command after both are present.
    // =====================================================================
    reg                                      aw_hold_valid;
    reg [C_S_AXI_ADDR_WIDTH-1:0]             awaddr_hold;

    reg                                      w_hold_valid;
    reg [C_S_AXI_DATA_WIDTH-1:0]             wdata_hold;
    reg [(C_S_AXI_DATA_WIDTH/8)-1:0]         wstrb_hold;

    reg                                      axi_bvalid;
    reg [1:0]                                axi_bresp;

    wire aw_fire;
    wire w_fire;
    wire write_fire;
    wire [2:0] write_word_offset;
    wire [1:0] MatMul_In_Offset;
    wire valid_write_offset;
    wire full_wstrb;
    wire MatMul_In_Valid;

    assign S_AXI_AWREADY = !aw_hold_valid && !axi_bvalid;
    assign S_AXI_WREADY  = !w_hold_valid && !axi_bvalid;
    assign S_AXI_BVALID  = axi_bvalid;
    assign S_AXI_BRESP   = axi_bresp;

    assign aw_fire = S_AXI_AWVALID && S_AXI_AWREADY;
    assign w_fire  = S_AXI_WVALID  && S_AXI_WREADY;

    assign write_fire = aw_hold_valid && w_hold_valid && !axi_bvalid;

    // Byte address -> 32-bit word address.
    // 0x00=0, 0x04=1, 0x08=2, 0x0C=3, 0x10=4.
    assign write_word_offset = awaddr_hold[ADDR_LSB+2:ADDR_LSB];
    assign MatMul_In_Offset = write_word_offset[1:0];

    // V2 accepts only 0x04, 0x08, 0x0C as writes.
    assign valid_write_offset =
        (write_word_offset == 3'd1) ||
        (write_word_offset == 3'd2) ||
        (write_word_offset == 3'd3);

    assign full_wstrb = &wstrb_hold;
    assign MatMul_In_Valid = write_fire && valid_write_offset && full_wstrb;

    // =====================================================================
    // AXI read buffering
    // =====================================================================
    reg                                      axi_rvalid;
    reg [C_S_AXI_DATA_WIDTH-1:0]             axi_rdata;
    reg [1:0]                                axi_rresp;

    wire ar_fire;
    wire [2:0] read_word_offset;
    wire valid_rcode_read;
    wire MatMul_In_Rcode_Read;

    assign S_AXI_ARREADY = !axi_rvalid;
    assign S_AXI_RVALID  = axi_rvalid;
    assign S_AXI_RDATA   = axi_rdata;
    assign S_AXI_RRESP   = axi_rresp;

    assign ar_fire = S_AXI_ARVALID && S_AXI_ARREADY;
    assign read_word_offset = S_AXI_ARADDR[ADDR_LSB+2:ADDR_LSB];
    assign valid_rcode_read = ar_fire && (read_word_offset == 3'd0);

    // Important V2 handshake:
    // This is asserted on the AR handshake, i.e. the same clock edge on which
    // the current RCODE is latched into axi_rdata.  Ctrl may then advance its
    // internal result index to the next class without changing the RDATA that
    // is already being returned for this AXI transaction.
    assign MatMul_In_Rcode_Read = valid_rcode_read;

    // =====================================================================
    // MatMul V2
    // =====================================================================
    wire [C_S_AXI_DATA_WIDTH-1:0] MatMul_Rcode;

    MatMul #(
        .BIT_OFFSET(2),
        .BIT_INSTR(C_S_AXI_DATA_WIDTH)
    ) u_MatMul (
        .CLK(S_AXI_ACLK),
        .RST(~S_AXI_ARESETN),

        .In_Valid(MatMul_In_Valid),
        .In_Offset(MatMul_In_Offset),
        .In_Instruction(wdata_hold),
        .In_Rcode_Read(MatMul_In_Rcode_Read),

        .Rcode_Out(MatMul_Rcode)
    );

    // =====================================================================
    // AXI write channel
    // =====================================================================
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            aw_hold_valid <= 1'b0;
            awaddr_hold <= {C_S_AXI_ADDR_WIDTH{1'b0}};

            w_hold_valid <= 1'b0;
            wdata_hold <= {C_S_AXI_DATA_WIDTH{1'b0}};
            wstrb_hold <= {(C_S_AXI_DATA_WIDTH/8){1'b0}};

            axi_bvalid <= 1'b0;
            axi_bresp <= 2'b00;
        end
        else begin
            if (aw_fire) begin
                awaddr_hold <= S_AXI_AWADDR;
                aw_hold_valid <= 1'b1;
            end

            if (w_fire) begin
                wdata_hold <= S_AXI_WDATA;
                wstrb_hold <= S_AXI_WSTRB;
                w_hold_valid <= 1'b1;
            end

            if (write_fire) begin
                aw_hold_valid <= 1'b0;
                w_hold_valid <= 1'b0;
                axi_bvalid <= 1'b1;

                // OKAY only for a full-word write to 0x04/0x08/0x0C.
                if (valid_write_offset && full_wstrb)
                    axi_bresp <= 2'b00;
                else
                    axi_bresp <= 2'b10;
            end

            if (axi_bvalid && S_AXI_BREADY)
                axi_bvalid <= 1'b0;
        end
    end

    // =====================================================================
    // AXI read channel
    //
    // Only 0x00 is readable.  RCODE is captured on AR acceptance and held
    // stable until the AXI master accepts RDATA.
    // =====================================================================
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_rvalid <= 1'b0;
            axi_rdata <= {C_S_AXI_DATA_WIDTH{1'b0}};
            axi_rresp <= 2'b00;
        end
        else begin
            if (ar_fire) begin
                axi_rvalid <= 1'b1;

                if (read_word_offset == 3'd0) begin
                    axi_rdata <= MatMul_Rcode;
                    axi_rresp <= 2'b00;
                end
                else begin
                    axi_rdata <= {C_S_AXI_DATA_WIDTH{1'b0}};
                    axi_rresp <= 2'b10;
                end
            end

            if (axi_rvalid && S_AXI_RREADY)
                axi_rvalid <= 1'b0;
        end
    end

endmodule
