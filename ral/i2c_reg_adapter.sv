//=============================================================================
// File          : i2c_reg_adapter.sv
// Description   : UVM RAL Adapter — translates between UVM register operations
//               : (uvm_reg_bus_op) and the bus-specific transaction type
//               : (i2c_cpu_seq_item).
//
// TEACHING NOTE — The Adapter is the "translator" in RAL:
//
//   RAL high-level:   reg_model.CTRL.write(status, 8'h01)
//                             ↓
//   Adapter.reg2bus() converts uvm_reg_bus_op → i2c_cpu_seq_item
//                             ↓
//   Sequencer passes  i2c_cpu_seq_item to the driver
//                             ↓
//   Driver wiggles    cpu_addr/cpu_wr/cpu_wdata pins on the interface
//                             ↓ (DUT responds)
//   Driver captures   cpu_rdata and stores it in the item
//                             ↓
//   Adapter.bus2reg() converts i2c_cpu_seq_item → uvm_reg_bus_op
//                             ↓
//   RAL updates its   mirror value with the read data
//
//   Without the adapter, RAL can't talk to your specific bus interface.
//   You write ONE adapter per bus type; all registers on that bus share it.
//
// KEY CONSTRUCTOR FLAGS:
//   supports_byte_enable = 0   : Our 8-bit register bus has no byte lanes
//   provides_responses   = 1   : The driver returns items with response data
//                                (needed for reads — driver fills cpu_rdata)
//
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_REG_ADAPTER_SV
`define I2C_REG_ADAPTER_SV

class i2c_reg_adapter extends uvm_reg_adapter;

    `uvm_object_utils(i2c_reg_adapter)

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    function new(string name = "i2c_reg_adapter");
        super.new(name);
        // Byte enable not used on this simple APB-like interface
        supports_byte_enable = 0;
        // Driver puts response data (cpu_rdata) back into the item
        // Setting provides_responses=1 tells RAL to wait for the item
        // to be returned before updating its mirror
        provides_responses   = 1;
    endfunction

    // ------------------------------------------------------------------
    // reg2bus — RAL → bus item
    // ------------------------------------------------------------------
    // Called when RAL wants to perform a register access.
    // rw.kind  : UVM_WRITE or UVM_READ
    // rw.addr  : register byte offset (e.g., 0x0 for CTRL)
    // rw.data  : data to write (meaningful only for UVM_WRITE)
    // Returns  : a uvm_sequence_item (actually i2c_cpu_seq_item) cast to base
    // ------------------------------------------------------------------
    virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
        i2c_cpu_seq_item item;
        item = i2c_cpu_seq_item::type_id::create("reg_item");

        // Map RAL bus op to our CPU register bus signals
        item.cpu_addr  = rw.addr[2:0];                    // 3-bit register select
        item.cpu_wr    = (rw.kind == UVM_WRITE) ? 1'b1 : 1'b0;  // write enable
        item.cpu_wdata = rw.data[7:0];                    // 8-bit write data

        `uvm_info("REG_ADAPT",
            $sformatf("reg2bus: kind=%s addr=0x%0h data=0x%02h",
                      rw.kind.name(), rw.addr, rw.data), UVM_HIGH)

        return item;
    endfunction

    // ------------------------------------------------------------------
    // bus2reg — bus item → RAL
    // ------------------------------------------------------------------
    // Called after the driver completes the transaction.
    // Converts the filled-in i2c_cpu_seq_item back to uvm_reg_bus_op
    // so RAL can update its mirror register with the read data.
    //
    // rw.data   : populated with cpu_rdata from the driver response
    // rw.status : UVM_IS_OK signals success to the RAL framework
    //             (UVM_NOT_OK would log an error and not update mirror)
    // ------------------------------------------------------------------
    virtual function void bus2reg(uvm_sequence_item bus_item,
                                   ref uvm_reg_bus_op rw);
        i2c_cpu_seq_item item;
        if (!$cast(item, bus_item)) begin
            `uvm_fatal("BUS2REG",
                "bus2reg: failed to cast bus_item to i2c_cpu_seq_item")
        end

        // Return the read data to RAL.
        // FIX (post-audit): rw.addr was never populated, violating the
        // documented bus2reg contract (explicit predictors and extended RAL
        // components read it from the returned bus op).
        rw.addr   = item.cpu_addr;
        rw.data   = {24'h0, item.cpu_rdata};  // zero-extend to 64-bit bus_op width
        rw.status = UVM_IS_OK;                 // always OK for this simple interface

        `uvm_info("REG_ADAPT",
            $sformatf("bus2reg: addr=0x%0h rdata=0x%02h",
                      item.cpu_addr, item.cpu_rdata), UVM_HIGH)
    endfunction

endclass : i2c_reg_adapter

`endif
