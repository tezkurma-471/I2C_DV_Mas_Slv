PART 1 - PHASE 1: PROTOCOL STUDY AND SYSTEM ARCHITECTURE (DAYS 1-2)
====================================================================

1.1 THE PHILOSOPHY OF READING BEFORE CODING
-------------------------------------------

When a senior design or verification engineer begins a new protocol block, the first
step is never to open an IDE and start typing code. The first step is deep, focused
study of the specification. For I2C, I dedicated Day 1 to reading NXP UM10204 Rev. 7.0
cover-to-cover. This is not optional.

Why? Because the specification contains edge cases that only appear in real hardware: open-drain behavior, clock stretching, multi-master arbitration, and the exact timing relationships between SDA and SCL. If you code without understanding these, you will produce an RTL block that passes basic tests and fails catastrophically in production.

Example of a real-world failure that stems from not reading the spec: A master generates a START condition by pulling SDA low while SCL is high. A junior engineer might code this as simultaneous SDA/SCL transitions, violating the mandatory 4.7 us setup time (t_SU:STA) and causing the slave to miss the START entirely on some temperature corners.

1.2 THE PHYSICAL BUS: OPEN-DRAIN AND WIRED-AND
---------------------------------------------

The I2C bus is physically two wires: Serial Data (SDA) and Serial Clock (SCL). Both
are open-drain with external pull-up resistors.

    VCC (3.3V)
      |
      R (pull-up, roughly 4.7k)
      |
      ---- SDA line ----|----> To all devices on the bus
      |                 |
      |                 |
    Master SDA driver   Slave SDA driver
    (sda_o, sda_oe)    (sda_o, sda_oe)

The rule of open-drain logic:
- If any device pulls the line LOW, the line is LOW for everyone.
- If all devices release the line (high-impedance), the pull-up resistor pulls it HIGH.
- No device can force the line HIGH. The only way it goes HIGH is by disconnecting.

Implication for RTL: Every bus-driving signal must be tri-state. Standard push-pull
logic (assign sda = 1'b1) defeats the open-drain mechanism. If two devices both pulled
the line HIGH and LOW simultaneously, you create a short circuit through the output
transistors. This is why I2C requires tri-state: driving LOW or releasing (Z) are the
only two valid bus states.

1.3 START, STOP, AND REPEATED START
-----------------------------------

START (S): SDA falls while SCL is HIGH.
STOP  (P): SDA rises while SCL is HIGH.
Repeated START (Sr): A START without a preceding STOP. Used to switch between write
                     and read modes or to address a different slave.

ASCII timing diagrams:

START:
  SCL:  _______|_____________ (HIGH when SDA falls)
  SDA: _________|____
               START (SDA falls here)

STOP:
  SCL:  _______|_____________ (HIGH when SDA rises)
  SDA: _____________|___
                 STOP (SDA rises here)

Repeated START:
  SCL:  _______|_____|___________ (two SCL HIGH periods without intervening STOP)
  SDA: _________|_____|___
               START then data then Sr

Timing parameters (Standard Mode 100 kHz):
  Parameter              Symbol      Min Value
  --------------------------------------------
  Setup time for Start   t_SU_STA    4.7 us
  Hold time for Start    t_HD_STA    4.0 us
  Setup time for SDA     t_SU_DAT    250 ns
  Hold time for SDA      t_HD_DAT    0 ns
  SCL Low Period         t_LOW       4.7 us
  SCL High Period        t_HIGH      4.0 us
  Setup time for Stop    t_SU_STO    4.0 us
  Bus free time          t_BUF       4.7 us

1.4 THE BYTE + ACK/NACK FRAME
-------------------------------

After a START, the first byte is the address byte, followed by an ACK. Every 8 bits
of data are also followed by an ACK.

  START  Address (7 bits) + R/W  ACK  Data (8 bits)  ACK  ...  STOP
    S   A6 A5 A4 A3 A2 A1 A0 RW  ACK D7 D6 D5 D4 D3 D2 D1 D0  ACK     P

ACK: Receiver pulls SDA LOW during the 9th SCL HIGH period. This signals the
transmitter that the byte was received successfully.

NACK: Receiver leaves SDA HIGH (does not pull it low). This tells the transmitter
to stop sending. The transmitter should respond with a STOP or Repeated START.

1.5 SYSTEM ARCHITECTURE
-------------------------

Block diagram (ASCII):

  +------------------------------------------------------------------
  |                     TOP TESTBENCH (top_tb.sv)                     |
  |  +-------------------------------------------------------------+ |
  |  |              I2C Interface (i2c_if.sv)                       | |
  |  |  SDA (wire)  <-------------------------------------->  SDA     | |
  |  |  SCL (wire)  <-------------------------------------->  SCL     | |
  |  +----------+--------------------------------------------+ | |
  |             |                                            |   |
  |  +----------v------------+    +------------------------v----+  |
  |  |  I2C Master         |    |  I2C Slave                  |  |
  |  |  (i2c_master.sv)    |    |  (i2c_slave.sv)             |  |
  |  |                     |    |                             |  |
  |  |  +---------------+  |    |  +------------------+      |  |
  |  |  | Controller    |  |    |  | Controller      |      |  |
  |  |  | FSM: IDLE     |  |    |  | FSM: IDLE       |      |  |
  |  |  | -> START    |  |    |  | -> ADDR          |      |  |
  |  |  | -> TX/RX    |  |    |  | -> RX/TX         |      |  |
  |  |  | -> STOP     |  |    |  | -> STOP          |      |  |
  |  |  +---------------+  |    |  +------------------+      |  |
  |  |                     |    |                             |  |
  |  |  CPU Interface      |    |  8-Register Bank            |  |
  |  |  (APB-like)       |    |                             |  |
  |  +---------------------+    +-----------------------------+  |
  |                                                               |
  +---------------------------------------------------------------+

In a real chip, a microcontroller (ARM Cortex-M, RISC-V) would write to the master's
registers via an APB bus. The master then drives the I2C bus. The slave listens to
the bus, responds to its own address, and uses an internal 8-register bank.

1.6 REGISTER INTERFACE DESIGN (APB-LIKE)
-----------------------------------------

The master controller exposes a simple register interface to the CPU:
  Address (3 bits) | Name       | Direction | Description
  -------------------------------------------------------------------
  3'h0             | REG_CTRL   | RW        | Control: enable, mode
  3'h1             | REG_CMD    | W         | Command: START, STOP, WRITE, READ
  3'h2             | REG_STATUS | R         | Status: IDLE, BUSY, ACK, DONE
  3'h3             | REG_DATA   | RW        | TX/RX data buffer
  3'h4             | REG_ADDR   | W         | Target slave address
  3'h5             | REG_IRQ_EN | RW        | Interrupt enable mask
  3'h6             | REG_IRQ_ST | R         | Interrupt status

Workflow for a write transaction:
  1. CPU writes target slave address to REG_ADDR
  2. CPU writes data byte            to REG_DATA
  3. CPU writes CMD_WRITE            to REG_CMD
  4. Controller generates START, sends address, sends data, waits for ACK, STOPs
  5. CPU reads REG_STATUS for completion

1.7 DIRECTORY STRUCTURE
-------------------------

i2c-protocol-dv/
  rtl/
    i2c_pkg.sv              -- Shared types, MUST compile first
    i2c_master_controller.sv
    i2c_master.sv
    i2c_slave_controller.sv
    i2c_slave.sv
  tb/
    i2c_if.sv               -- SystemVerilog Interface (open-drain bus abstraction)
    top_tb.sv               -- Top-level testbench
  uvm/
    (UVM Environment - Phase 4)
  sva/
    (SVA Assertions - Phase 6)

Compilation order is critical: i2c_pkg -> i2c_if -> controllers -> wrappers -> top_tb.
