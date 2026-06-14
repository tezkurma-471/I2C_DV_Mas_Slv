//=============================================================================
// File          : i2c_cpu_seq_item.sv
// Description   : UVM Sequence Item for the I2C master CPU register bus.
//               : Represents a single register read or write transaction.
//
// TEACHING NOTE — WHY a separate seq_item for the CPU interface?
//   The existing i2c_seq_item.sv models a full I2C bus TRANSACTION (start,
//   address phase, data bytes, stop).  That's a PROTOCOL-level item.
//
//   This item is a REGISTER-LEVEL item — it models one CPU register access:
//     cpu_addr [2:0]  → which register (maps to i2c_reg_e)
//     cpu_wr          → read or write
//     cpu_wdata [7:0] → value to write
//     cpu_rdata [7:0] → value read back (filled by driver, not randomized)
//
//   The RAL framework calls reg2bus() in the adapter to convert a
//   uvm_reg_bus_op into one of these items, then hands it to the driver.
//
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_CPU_SEQ_ITEM_SV
`define I2C_CPU_SEQ_ITEM_SV

class i2c_cpu_seq_item extends uvm_sequence_item;

    `uvm_object_utils(i2c_cpu_seq_item)

    // ------------------------------------------------------------------
    // Fields
    // ------------------------------------------------------------------
    rand logic [2:0] cpu_addr;    // Register select (i2c_reg_e offset)
    rand logic       cpu_wr;      // 1=write, 0=read
    rand logic [7:0] cpu_wdata;   // Data to write (ignored on reads)
    logic      [7:0] cpu_rdata;   // Data read back — NOT rand, filled by driver

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    function new(string name = "i2c_cpu_seq_item");
        super.new(name);
    endfunction

    // ------------------------------------------------------------------
    // do_copy — deep copy for clone() calls inside UVM
    // ------------------------------------------------------------------
    // The UVM sequencer calls copy() internally when moving items between
    // phase boundaries.  Without do_copy, cloned items lose field values.
    // ------------------------------------------------------------------
    function void do_copy(uvm_object rhs);
        i2c_cpu_seq_item rhs_cast;
        super.do_copy(rhs);
        if (!$cast(rhs_cast, rhs)) begin
            `uvm_fatal("DO_COPY", "Cast failed in i2c_cpu_seq_item::do_copy")
        end
        cpu_addr  = rhs_cast.cpu_addr;
        cpu_wr    = rhs_cast.cpu_wr;
        cpu_wdata = rhs_cast.cpu_wdata;
        cpu_rdata = rhs_cast.cpu_rdata;
    endfunction

    // ------------------------------------------------------------------
    // do_print — used by `uvm_info and .print()
    // ------------------------------------------------------------------
    function void do_print(uvm_printer p);
        super.do_print(p);
        p.print_field_int("cpu_addr",  cpu_addr,  3, UVM_HEX);
        p.print_field_int("cpu_wr",    cpu_wr,    1, UVM_BIN);
        p.print_field_int("cpu_wdata", cpu_wdata, 8, UVM_HEX);
        p.print_field_int("cpu_rdata", cpu_rdata, 8, UVM_HEX);
    endfunction

    // ------------------------------------------------------------------
    // convert2string — one-liner for log messages
    // ------------------------------------------------------------------
    function string convert2string();
        return $sformatf("[CPU_REG] addr=0x%0h wr=%0b wdata=0x%02h rdata=0x%02h",
                         cpu_addr, cpu_wr, cpu_wdata, cpu_rdata);
    endfunction

endclass : i2c_cpu_seq_item

`endif
