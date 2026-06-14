//=============================================================================
// File          : i2c_ral_env.sv
// Description   : UVM RAL Environment — top-level container for all RAL test
//               : components.  Intentionally separate from i2c_env.sv to
//               : avoid coupling with the slave/bus environment.
//
// TEACHING NOTE — RAL Environment architecture:
//
//   i2c_ral_env
//     ├── i2c_cpu_agent         (driver + sequencer for cpu bus)
//     ├── i2c_master_reg_block  (the RAL register model)
//     ├── i2c_reg_adapter       (translates reg ops ↔ cpu seq items)
//     └── (no predictor — using set_auto_predict instead)
//
//   PREDICTOR vs AUTO-PREDICT:
//   The full UVM RAL flow includes a uvm_reg_predictor component that
//   connects to a monitor's analysis port.  The monitor observes actual
//   bus transactions and the predictor updates the RAL mirror accordingly.
//
//   Since we have no register bus monitor in this simple agent, we use
//   set_auto_predict(1) instead.  With auto-predict:
//     - After every reg.write(), RAL automatically updates the mirror
//       with the written value (no monitor/predictor needed)
//     - After every reg.read(), RAL updates the mirror with the readback
//
//   Limitation: auto-predict can't catch side-effects (e.g., DUT clearing
//   a field after read).  For that, you'd add a monitor + predictor later.
//
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_RAL_ENV_SV
`define I2C_RAL_ENV_SV

class i2c_ral_env extends uvm_env;

    `uvm_component_utils(i2c_ral_env)

    // ------------------------------------------------------------------
    // Sub-components
    // ------------------------------------------------------------------
    i2c_cpu_agent         cpu_agent;   // drives the CPU register bus
    i2c_master_reg_block  reg_model;   // RAL register model
    i2c_reg_adapter       reg_adapter; // translates reg ops ↔ seq items

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    function new(string name = "i2c_ral_env", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // ------------------------------------------------------------------
    // build_phase
    // ------------------------------------------------------------------
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // Create the CPU agent (ACTIVE — drives the bus)
        cpu_agent = i2c_cpu_agent::type_id::create("cpu_agent", this);

        // Create the register model (uvm_object, not component — no parent arg)
        reg_model = i2c_master_reg_block::type_id::create("reg_model");
        reg_model.build();    // build() populates registers + address map

        // Create the adapter (uvm_object)
        reg_adapter = i2c_reg_adapter::type_id::create("reg_adapter");

        // Publish the register model in config_db so sequences can retrieve it
        // Using "*" path so any sequence in any test can find it
        uvm_config_db #(i2c_master_reg_block)::set(this, "*", "reg_model", reg_model);

    endfunction

    // ------------------------------------------------------------------
    // connect_phase
    // ------------------------------------------------------------------
    function void connect_phase(uvm_phase phase);

        // Wire the RAL map to the CPU agent's sequencer via the adapter.
        //
        // TEACHING NOTE:
        //   set_sequencer(seqr, adapter) tells the RAL map:
        //     "When you need to perform a register access, send the transaction
        //      through THIS sequencer, translated by THIS adapter."
        //   This is what makes reg_model.CTRL.write() end up on the physical bus.
        reg_model.default_map.set_sequencer(cpu_agent.sequencer, reg_adapter);

        // Enable auto-predict mode on the default map.
        //
        //   With auto-predict ON:
        //     After reg.write(status, val) → mirror is updated to val automatically
        //     After reg.read(status, val)  → mirror is updated to returned val
        //
        //   This replaces the need for a monitor + uvm_reg_predictor component.
        //   Acceptable for a register-only testbench where we control all accesses.
        reg_model.default_map.set_auto_predict(1);

        `uvm_info("RAL_ENV", "connect_phase: RAL map connected to cpu_agent sequencer", UVM_LOW)

    endfunction

endclass : i2c_ral_env

`endif
