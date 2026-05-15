PART 2 - PHASE 2: I2C MASTER RTL (DAYS 3-5)
=============================================

File: `i2c_pkg.sv`
-------------------
Total Lines: 135
Compilation Order: FIRST (all other RTL files import this)
Role: Shared package containing parameters, enums, and type definitions

Section-by-section explanation:

Include guards (lines 11-12):
  `ifndef I2C_PKG_SV
  `define I2C_PKG_SV

Why include guards? SystemVerilog does not have a linker like C++. When you
`include or import a file, the compiler processes it inline. If two other files
both import i2c_pkg, the compiler sees the package twice. The `ifndef / `define
pair creates a compile-time guard. If I2C_PKG_SV is not defined, the file is
processed. If it IS defined (because another file already processed it), the
file is skipped entirely. This prevents redefinition errors.

package declaration (line 14):
  `package i2c_pkg;`

SystemVerilog packages are a mechanism for scoping declarations (types, functions,
parameters) that are NOT tied to a specific module. They get compiled into a
separate compilation unit and can be imported by any other SystemVerilog source.
Using `import i2c_pkg::*` brings all public declarations into the current scope.

Parameter: CLK_FREQ_MHZ (line 27):
  `parameter int CLK_FREQ_MHZ = 50;`

This is the central clock frequency knob. The entire timing system is built around
it. All following parameters (T_SCL_PERIOD, etc.) are derived from this value.
If we change the system clock from 50 MHz to 100 MHz, we only change this one
parameter and the entire timing system adjusts automatically.

The `int` type is parameterizable at compile time but creates a signed integer.
For counters, unsigned would be safer, but since all derived values are positive,
this is acceptable. A future refinement would use `parameter int unsigned`.

Parameters: T_SCL_PERIOD, T_SCL_HIGH, T_SCL_LOW (lines 31-33):
  parameter int T_SCL_PERIOD = 500;
  parameter int T_SCL_HIGH   = 250;
  parameter int T_SCL_LOW    = 250;

These define the SCL clock timing in terms of system clock ticks:
  - T_SCL_PERIOD = 500 ticks at 50 MHz = 500 * 20 ns = 10,000 ns = 10 us
    This gives an SCL frequency of 1/10us = 100 kHz (Standard Mode)
  - T_SCL_HIGH = 250 ticks = 250 * 20 ns = 5,000 ns = 5 us
    This is the SCL HIGH time
  - T_SCL_LOW = 250 ticks = 5,000 ns = 5 us
    This is the SCL LOW time

The sum T_SCL_HIGH + T_SCL_LOW = 10 us = T_SCL_PERIOD.

Parameter: MAX_CLK_STRETCH (line 45):
  parameter int MAX_CLK_STRETCH = 1000;

This is the maximum number of system clock cycles the master will wait for the
slave to release SCL during clock stretching. After 1000 cycles (20 us at 50 MHz),
the master declares a timeout. This is a safety mechanism: without it, a slave
that holds SCL low forever (or a dead slave) would stall the master forever.

Parameter: DATA_WIDTH, ADDR_WIDTH (lines 48-49):
  parameter int DATA_WIDTH = 8;
  parameter int ADDR_WIDTH = 7;

These are self-documenting parameters for data and address bus widths. The I2C
spec uses 7-bit addressing and 8-bit data. Even though these are fixed by the spec,
using parameters instead of hardcoded numbers improves code readability and
maintainability. If we ever needed 10-bit addressing (as supported by the spec),
we would change ADDR_WIDTH without touching any other code.

Enumerations (lines 57-83):

Command enumeration (lines 57-66):
  typedef enum logic [3:0] {
    CMD_NOP        = 4'h0,
    ...
  } i2c_cmd_e;

This defines the opcode encoding for host CPU commands. The CPU writes these
values into the CMD register to instruct the master controller what to do next.
CMD_START     (4'h1): Generate a START condition on the bus
CMD_STOP      (4'h2): Generate a STOP condition on the bus
CMD_WRITE     (4'h3): Write the data in the DATA register to the slave
CMD_READ_ACK  (4'h4): Read a byte from the slave and ACK it (read more)
CMD_READ_NACK (4'h5): Read a byte from the slave and NACK it (last byte)
CMD_REP_START (4'h6): Generate a Repeated START (Sr)
CMD_ABORT     (4'h7): Abort current operation

Why `logic [3:0]` instead of `int`? Because this enum is used to drive 4-bit logic
signals inside the FSM, and using `logic` ensures exact width and synthesizability.

Status enumeration (lines 75-84):
  typedef enum logic [2:0] {
    STS_IDLE     = 3'b000,
    ...
    STS_DONE     = 3'b110,
    STS_ERR      = 3'b111
  } i2c_status_e;

These codes are returned in the STATUS register for the CPU to poll. The CPU
can check if a transaction is complete by reading STS_DONE.

Register map enumeration (lines 106-114):
  typedef enum logic [2:0] {
    REG_CTRL   = 3'h0,
    ...
    REG_IRQ_ST = 3'h6
  } i2c_reg_e;

This maps the APB-like register addresses. The CPU uses these offsets to
read/write the master control registers. Encoding them as an enum rather than
raw numbers prevents errors when the register map changes.

Function: build_addr_byte (lines 120-125):
  function automatic addr_byte_t build_addr_byte(
    logic [6:0] addr,
    i2c_dir_e   dir
  );
    return {addr, dir};
  endfunction

This function constructs an 8-bit I2C address byte from a 7-bit address and a
direction bit. Per the spec, the address byte format is {7-bit addr, 1-bit R/W}.
Using a named function makes the code self-documenting: instead of manually
concatenating `{addr, dir}` everywhere (which could have the wrong bit order),
we use `build_addr_byte(addr, dir)`.

Function: is_valid_addr (lines 128-131):
  function automatic logic is_valid_addr(addr_byte_t addr_byte);
    return !((addr_byte[7:4] == 4'b0000) || (addr_byte[7:4] == 4'b1111));
  endfunction

Checks if the upper 4 bits of an address byte are in the reserved ranges. The I2C
spec reserves 0000_XXX and 1111_XXX for special purposes. This is used in the
testbench to filter out invalid random addresses.
