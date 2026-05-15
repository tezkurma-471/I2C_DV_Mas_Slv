//=============================================================================
// File          : i2c_slave_monitor.sv
// Description   : UVM Monitor for I2C Slave DUT status signals
//               : Observes addr_match, active, rx_data_valid, etc. and
//               : creates slave_status transactions for analysis.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_SLAVE_MONITOR_SV
`define I2C_SLAVE_MONITOR_SV

class i2c_slave_status_item extends uvm_sequence_item;

  `uvm_object_utils(i2c_slave_status_item)

  logic [7:0] rx_data;
  bit         rx_data_valid;
  bit         addr_match;
  bit         active;
  bit         tx_ack;
  bit         tx_nack;
  bit         bus_error;
  logic [7:0] reg_bank [0:7];

  function new(string name = "i2c_slave_status_item");
    super.new(name);
  endfunction

  virtual function string convert2string();
    string s;
    s = $sformatf("slave_status: addr_match=%0b active=%0b rx_valid=%0b rx_data=0x%02x tx_ack=%0b tx_nack=%0b bus_err=%0b",
                  addr_match, active, rx_data_valid, rx_data, tx_ack, tx_nack, bus_error);
    return s;
  endfunction

endclass

class i2c_slave_monitor extends uvm_monitor;

  `uvm_component_utils(i2c_slave_monitor)

  virtual i2c_slave_if vif;

  uvm_analysis_port #(i2c_slave_status_item) status_port;

  function new(string name = "i2c_slave_monitor", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    status_port = new("status_port", this);
    if (!uvm_config_db#(virtual i2c_slave_if)::get(this, "", "i2c_slave_vif", vif)) begin
      `uvm_fatal(get_type_name(), "i2c_slave_vif not found in config_db")
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    forever begin
      @(posedge vif.clk);
      if (vif.rx_data_valid || vif.addr_match || vif.bus_error) begin
        i2c_slave_status_item item = i2c_slave_status_item::type_id::create("slv_status");
        item.rx_data       = vif.rx_data;
        item.rx_data_valid = vif.rx_data_valid;
        item.addr_match    = vif.addr_match;
        item.active        = vif.active;
        item.tx_ack        = vif.tx_ack;
        item.tx_nack       = vif.tx_nack;
        item.bus_error     = vif.bus_error;
        foreach (vif.reg_bank[i])
          item.reg_bank[i] = vif.reg_bank[i];
        `uvm_info(get_type_name(), item.convert2string(), UVM_HIGH)
        status_port.write(item);
      end
    end
  endtask

endclass : i2c_slave_monitor

`endif
