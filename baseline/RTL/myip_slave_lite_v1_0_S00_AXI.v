`timescale 1 ns / 1 ps

module myip_slave_lite_v1_0_S00_AXI #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 5
)(
    // Global
    input  wire                              S_AXI_ACLK,
    input  wire                              S_AXI_ARESETN,

    // Write address
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     S_AXI_AWADDR,
    input  wire [2:0]                        S_AXI_AWPROT,
    input  wire                              S_AXI_AWVALID,
    output wire                              S_AXI_AWREADY,

    // Write data
    input  wire [C_S_AXI_DATA_WIDTH-1:0]     S_AXI_WDATA,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] S_AXI_WSTRB,
    input  wire                              S_AXI_WVALID,
    output wire                              S_AXI_WREADY,

    // Write response
    output wire [1:0]                        S_AXI_BRESP,
    output wire                              S_AXI_BVALID,
    input  wire                              S_AXI_BREADY,

    // Read address
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     S_AXI_ARADDR,
    input  wire [2:0]                        S_AXI_ARPROT,
    input  wire                              S_AXI_ARVALID,
    output wire                              S_AXI_ARREADY,

    // Read data
    output wire [C_S_AXI_DATA_WIDTH-1:0]     S_AXI_RDATA,
    output wire [1:0]                        S_AXI_RRESP,
    output wire                              S_AXI_RVALID,
    input  wire                              S_AXI_RREADY
);

    localparam integer ADDR_LSB = 2;

    // ============================================================
    // AXI Write Buffer
    //
    // AXI4-Lite AW and W are independent channels.
    // Store them separately, then issue one MatMul command when
    // both have arrived.
    // ============================================================

    reg aw_hold_valid;
    reg [C_S_AXI_ADDR_WIDTH-1:0] awaddr_hold;

    reg w_hold_valid;
    reg [C_S_AXI_DATA_WIDTH-1:0] wdata_hold;
    reg [(C_S_AXI_DATA_WIDTH/8)-1:0] wstrb_hold;

    reg axi_bvalid;
    reg [1:0] axi_bresp;

    assign S_AXI_AWREADY = !aw_hold_valid && !axi_bvalid;
    assign S_AXI_WREADY  = !w_hold_valid && !axi_bvalid;

    assign S_AXI_BVALID = axi_bvalid;
    assign S_AXI_BRESP  = axi_bresp;

    wire aw_fire = S_AXI_AWVALID && S_AXI_AWREADY;
    wire w_fire  = S_AXI_WVALID  && S_AXI_WREADY;

    // Both address and data have been captured.
    wire write_fire = aw_hold_valid && w_hold_valid && !axi_bvalid;

    // Word offset:
    // 0x00 -> 0
    // 0x04 -> 1
    // 0x08 -> 2
    // 0x0C -> 3
    // 0x10 -> 4
    wire [2:0] cmd_offset = awaddr_hold[4:2];

    wire valid_cmd_offset = (cmd_offset >= 3'd1) && (cmd_offset <= 3'd4);
    wire full_wstrb = &wstrb_hold;

    // MatMul receives one command pulse only for valid write commands.
    wire MatMul_In_Valid = write_fire && valid_cmd_offset && full_wstrb;


    // ============================================================
    // AXI Read
    // ============================================================

    reg axi_rvalid;
    reg [C_S_AXI_DATA_WIDTH-1:0] axi_rdata;
    reg [1:0] axi_rresp;

    assign S_AXI_ARREADY = !axi_rvalid;
    assign S_AXI_RVALID  = axi_rvalid;
    assign S_AXI_RDATA   = axi_rdata;
    assign S_AXI_RRESP   = axi_rresp;

    wire ar_fire = S_AXI_ARVALID && S_AXI_ARREADY;


    // ============================================================
    // MatMul
    // ============================================================

    wire [C_S_AXI_DATA_WIDTH-1:0] MatMul_Rcode;

    MatMul #(
        .BIT_OFFSET(3),
        .BIT_INSTR(C_S_AXI_DATA_WIDTH)
    ) u_MatMul (
        .CLK(S_AXI_ACLK),
        .RST(~S_AXI_ARESETN),

        .In_Valid(MatMul_In_Valid),
        .In_Offset(cmd_offset),
        .In_Instruction(wdata_hold),

        .Rcode_Out(MatMul_Rcode)
    );


    // ============================================================
    // AXI Write Channel
    // ============================================================

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            aw_hold_valid <= 1'b0;
            awaddr_hold <= 0;

            w_hold_valid <= 1'b0;
            wdata_hold <= 0;
            wstrb_hold <= 0;

            axi_bvalid <= 1'b0;
            axi_bresp <= 2'b00;
        end
        else begin
            // Capture AW independently.
            if (aw_fire) begin
                awaddr_hold <= S_AXI_AWADDR;
                aw_hold_valid <= 1'b1;
            end

            // Capture W independently.
            if (w_fire) begin
                wdata_hold <= S_AXI_WDATA;
                wstrb_hold <= S_AXI_WSTRB;
                w_hold_valid <= 1'b1;
            end

            // Issue exactly one command once AW + W are available.
            if (write_fire) begin
                aw_hold_valid <= 1'b0;
                w_hold_valid <= 1'b0;

                axi_bvalid <= 1'b1;

                // OKAY for 0x04~0x10 full-word writes.
                // SLVERR for unsupported address / partial write.
                if (valid_cmd_offset && full_wstrb) axi_bresp <= 2'b00;
                else axi_bresp <= 2'b10;
            end

            // PS accepted write response.
            if (axi_bvalid && S_AXI_BREADY) begin
                axi_bvalid <= 1'b0;
            end
        end
    end


    // ============================================================
    // AXI Read Channel
    //
    // Only 0x00 is readable:
    //
    // 0x00 -> {BUSY, DONE, PENDING, VALID, DATA[27:0]}
    //
    // RDATA is latched when AR is accepted so it remains stable
    // until the PS completes the AXI read.
    // ============================================================

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_rvalid <= 1'b0;
            axi_rdata <= 0;
            axi_rresp <= 2'b00;
        end
        else begin
            if (ar_fire) begin
                axi_rvalid <= 1'b1;

                case (S_AXI_ARADDR[4:2])
                    3'd0: begin
                        axi_rdata <= MatMul_Rcode;
                        axi_rresp <= 2'b00;
                    end

                    default: begin
                        axi_rdata <= 0;
                        axi_rresp <= 2'b10;
                    end
                endcase
            end

            if (axi_rvalid && S_AXI_RREADY) begin
                axi_rvalid <= 1'b0;
            end
        end
    end

endmodule