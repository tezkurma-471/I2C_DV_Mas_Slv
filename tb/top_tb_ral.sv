//=============================================================================
// File          : top_tb_ral.sv
// Description   : Top-level testbench for UVM RAL (Register Abstraction Layer)
//               : tests targeting the i2c_master_controller's CPU register
//               : interface.
//
// TEACHING NOTE — WHY a separate top for RAL tests?
//   The existing top_tb.sv instantiates the I2C SLAVE and drives the bus via
//   a BFM driver.  RAL tests have a completely different goal: they test that
//   the CPU register interface (cpu_addr/cpu_wr/cpu_wdata/cpu_rdata) works
//   correctly — essentially unit-testing the register map.
//
//   We DON'T need the slave DUT, the I2C bus assertions, or the slave agent.
//   Instantiating only what we need keeps compile time low and the test intent
//   crystal-clear.  The SCL/SDA pins are tied to 1 (pulled-up / released)
//   because the master will never see a valid I2C device to talk to — that
//   is intentional.  We are only poking registers, not driving the bus.
//
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef TOP_TB_RAL_SV
`define TOP_TB_RAL_SV

`include "uvm_macros.svh"
import uvm_pkg::*;
import i2c_pkg::*;
import i2c_tb_ral_pkg::*;

module top_tb_ral;

    // ------------------------------------------------------------------
    // Clock & Reset
    // ------------------------------------------------------------------
    logic clk;
    logic rst_n;

    initial begin
        clk = 1'b0;
        forever #10 clk = ~clk;   // 50 MHz — same as main TB
    end

    initial begin
        rst_n = 1'b0;
        #100 rst_n = 1'b1;        // 5-cycle reset (register tests need minimal reset)
    end

    // ------------------------------------------------------------------
    // Register Interface (CPU bus)
    // ------------------------------------------------------------------
    i2c_reg_if u_reg_if (.clk(clk), .rst_n(rst_n));

    // ------------------------------------------------------------------
    // SCL / SDA: tri-state bus with pull-ups
    // ------------------------------------------------------------------
    // The master will drive SCL/SDA low (open-drain), but since no slave
    // is connected the lines float to 1 via the pull-up.
    // Using wire + pullup is the correct RTL-simulation idiom.
    // ------------------------------------------------------------------
    wire scl;
    wire sda;

    pullup (scl);
    pullup (sda);

    // ------------------------------------------------------------------
    // DUT: I2C Master Controller
    // ------------------------------------------------------------------
    // Only the CPU register interface is connected to the interface.
    // The physical I2C pins go to the open-drain bus above.
    // Other status outputs (busy, done, ack, etc.) are left unconnected
    // because RAL tests don't need them — the register model covers that.
    // ------------------------------------------------------------------
    i2c_master_controller dut (
        .clk       (clk),
        .rst_n     (rst_n),

        // CPU register interface — driven by RAL via i2c_reg_if
        .cpu_addr  (u_reg_if.cpu_addr),
        .cpu_wr    (u_reg_if.cpu_wr),
        .cpu_wdata (u_reg_if.cpu_wdata),
        .cpu_rdata (u_reg_if.cpu_rdata),
        .cpu_irq   (),           // not needed for RAL tests

        // Physical I2C bus
        .scl       (scl),
        .sda       (sda),

        // Status outputs — floated, RAL reads status via register reads
        .busy      (),
        .done      (),
        .ack       (),
        .nack      (),
        .timeout   (),
        .bus_error (),
        .arb_lost  ()
    );

    // ------------------------------------------------------------------
    // Config DB — publish the virtual interface for the cpu_agent driver
    // ------------------------------------------------------------------
    // Using wildcard path "*" so the handle reaches the driver regardless
    // of where it lives in the UVM hierarchy.
    // ------------------------------------------------------------------
    initial begin
        uvm_config_db #(virtual i2c_reg_if)::set(null, "*", "reg_vif", u_reg_if);
        run_test();   // +UVM_TESTNAME selects the specific RAL test
    end

    // ------------------------------------------------------------------
    // Waveform Dump
    // ------------------------------------------------------------------
    initial begin
        $dumpfile("ral_waves.vcd");
        $dumpvars(0, top_tb_ral);
    end

    // ------------------------------------------------------------------
    // Global Timeout
    // ------------------------------------------------------------------
    initial begin
        #5_000_000;   // 5ms — RAL register tests should complete well within 1ms
        $error("TIMEOUT: RAL simulation exceeded 5ms");
        $finish;
    end

endmodule : top_tb_ral

`endif
