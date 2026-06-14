//=============================================================================
// File          : i2c_cpu_agent.sv
// Description   : UVM Agent for the I2C master CPU register interface.
//               : Packages the driver + sequencer into one reusable component.
//               : No monitor for now — RAL env uses set_auto_predict() instead.
//
// TEACHING NOTE — Agent structure:
//   An Agent bundles:
//     - Sequencer : decides what to send (receives items from sequences)
//     - Driver    : converts items into interface-level pin wiggling
//     - Monitor   : observes pin activity and reconstructs transactions
//                   (omitted here; set_auto_predict(1) in env replaces it)
//
//   The sequencer here is a plain uvm_sequencer parameterized on
//   i2c_cpu_seq_item.  No custom sequencer class needed because there is
//   no special arbitration logic required.
//
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_CPU_AGENT_SV
`define I2C_CPU_AGENT_SV

class i2c_cpu_agent extends uvm_agent;

    `uvm_component_utils(i2c_cpu_agent)

    // ------------------------------------------------------------------
    // Sub-components
    // ------------------------------------------------------------------
    i2c_cpu_driver                    driver;
    uvm_sequencer #(i2c_cpu_seq_item) sequencer;

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    function new(string name = "i2c_cpu_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // ------------------------------------------------------------------
    // build_phase — instantiate driver and sequencer
    // ------------------------------------------------------------------
    // uvm_agent.is_active is set in config_db by the environment or test.
    // Default is UVM_ACTIVE (drives the interface).  If UVM_PASSIVE, the
    // driver and sequencer are not created — only a monitor would exist.
    // For RAL we always run ACTIVE.
    // ------------------------------------------------------------------
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (get_is_active() == UVM_ACTIVE) begin
            driver    = i2c_cpu_driver::type_id::create("driver",    this);
            sequencer = uvm_sequencer #(i2c_cpu_seq_item)::type_id::create(
                            "sequencer", this);
        end
    endfunction

    // ------------------------------------------------------------------
    // connect_phase — wire driver's port to sequencer's export
    // ------------------------------------------------------------------
    // TEACHING NOTE:
    //   driver.seq_item_port  → uvm_seq_item_pull_port (driver asks for items)
    //   sequencer.seq_item_export → uvm_seq_item_pull_imp  (sequencer holds items)
    //   Connecting them lets the driver call get_next_item() on the sequencer.
    // ------------------------------------------------------------------
    function void connect_phase(uvm_phase phase);
        if (get_is_active() == UVM_ACTIVE) begin
            driver.seq_item_port.connect(sequencer.seq_item_export);
        end
    endfunction

endclass : i2c_cpu_agent

`endif
