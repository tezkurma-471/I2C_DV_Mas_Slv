//=============================================================================
// File          : i2c_cpu_driver.sv
// Description   : UVM Driver for the I2C master CPU register interface.
//               : Converts i2c_cpu_seq_item transactions into pin-level
//               : activity on the i2c_reg_if clocking block.
//
// TEACHING NOTE — How the RAL driver fits in:
//   Normal UVM driver flow:
//     Sequence → seq_item → Driver → Interface → DUT
//
//   RAL driver flow:
//     RAL (reg.write/read) → uvm_reg_bus_op → Adapter.reg2bus()
//     → i2c_cpu_seq_item → THIS DRIVER → i2c_reg_if → DUT cpu_* pins
//
//   The driver is the bridge between UVM objects and actual HDL signals.
//   It must:
//     1. Assert cpu_addr, cpu_wr, cpu_wdata for ONE clock cycle.
//     2. On reads: sample cpu_rdata one cycle later and store into item.
//     3. De-assert all outputs after each transaction (bus courtesy).
//     4. Call item_done() to free the sequencer for the next item.
//
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_CPU_DRIVER_SV
`define I2C_CPU_DRIVER_SV

class i2c_cpu_driver extends uvm_driver #(i2c_cpu_seq_item);

    `uvm_component_utils(i2c_cpu_driver)

    // Virtual interface handle.
    // FIX (post-audit): was declared `virtual i2c_reg_if.drv_mp` while the
    // config_db get below requests `virtual i2c_reg_if` — a TYPE MISMATCH
    // that fails at build time. The handle now matches the config_db type;
    // clocking-block discipline is preserved because all accesses go through
    // vif.driver_cb.
    virtual i2c_reg_if vif;

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    function new(string name = "i2c_cpu_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // ------------------------------------------------------------------
    // build_phase — get virtual interface from config_db
    // ------------------------------------------------------------------
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual i2c_reg_if)::get(this, "", "reg_vif", vif)) begin
            `uvm_fatal("NO_VIF",
                "i2c_cpu_driver: reg_vif not found in config_db. "
                "Check that top_tb_ral.sv sets it before run_test().")
        end
    endfunction

    // ------------------------------------------------------------------
    // run_phase — main driver loop
    // ------------------------------------------------------------------
    // TIMING CONTRACT (synchronous register interface):
    //   Cycle 0 : Drive cpu_addr, cpu_wr, cpu_wdata via clocking block.
    //             For WRITE: DUT latches on this posedge.
    //             For READ : DUT responds combinationally → cpu_rdata valid.
    //   Cycle 1 : Sample cpu_rdata (1 extra cycle to let comb logic settle
    //             through the clocking block's #1step input skew).
    //   After  : De-assert all outputs. Call item_done().
    //
    // NOTE: The clocking block automatically aligns all drives/samples to
    // posedge clk, so @(vif.driver_cb) advances by exactly one clock cycle.
    // ------------------------------------------------------------------
    task run_phase(uvm_phase phase);
        i2c_cpu_seq_item req;

        // De-assert everything at start of simulation
        vif.driver_cb.cpu_addr  <= 3'b000;
        vif.driver_cb.cpu_wr    <= 1'b0;
        vif.driver_cb.cpu_wdata <= 8'h00;

        // Wait for reset to deassert before driving any transactions
        @(posedge vif.clk);
        wait(vif.rst_n === 1'b1);
        @(vif.driver_cb);  // align to clocking block edge

        forever begin
            // --------------------------------------------------------
            // Step 1: Get next item from the sequencer (blocks if empty)
            // --------------------------------------------------------
            seq_item_port.get_next_item(req);

            `uvm_info("CPU_DRV",
                $sformatf("Driving: %s", req.convert2string()), UVM_MEDIUM)

            // --------------------------------------------------------
            // Step 2: Drive transaction for ONE clock cycle
            // --------------------------------------------------------
            vif.driver_cb.cpu_addr  <= req.cpu_addr;
            vif.driver_cb.cpu_wr    <= req.cpu_wr;
            vif.driver_cb.cpu_wdata <= req.cpu_wdata;

            @(vif.driver_cb);  // wait one full clock cycle

            // --------------------------------------------------------
            // Step 3: For READ, sample cpu_rdata
            // --------------------------------------------------------
            // The DUT drives cpu_rdata combinationally based on cpu_addr.
            // After the clocking block edge (#1step skew), the value is stable.
            // We wait one more cycle to be safe with the registered path.
            // --------------------------------------------------------
            if (!req.cpu_wr) begin
                // De-assert after first cycle so DUT sees a clean pulse
                vif.driver_cb.cpu_addr  <= req.cpu_addr;  // keep addr stable for read
                vif.driver_cb.cpu_wr    <= 1'b0;
                vif.driver_cb.cpu_wdata <= 8'h00;
                @(vif.driver_cb);
                // Sample rdata from clocking block (already #1step skewed)
                req.cpu_rdata = vif.driver_cb.cpu_rdata;

                `uvm_info("CPU_DRV",
                    $sformatf("Read back: addr=0x%0h rdata=0x%02h",
                              req.cpu_addr, req.cpu_rdata), UVM_HIGH)
            end

            // --------------------------------------------------------
            // Step 4: De-assert all outputs (clean bus between transactions)
            // --------------------------------------------------------
            vif.driver_cb.cpu_addr  <= 3'b000;
            vif.driver_cb.cpu_wr    <= 1'b0;
            vif.driver_cb.cpu_wdata <= 8'h00;
            @(vif.driver_cb);  // one idle cycle between transactions

            // --------------------------------------------------------
            // Step 5: Notify sequencer that item is complete
            // --------------------------------------------------------
            seq_item_port.item_done();
        end
    endtask

endclass : i2c_cpu_driver

`endif
