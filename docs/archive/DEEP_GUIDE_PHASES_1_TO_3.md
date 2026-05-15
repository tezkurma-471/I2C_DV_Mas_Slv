# I2C Protocol RTL + UVM Verification - COMPLETE MASTER GUIDE: PHASES 1, 2, 3
#### Deep Engineering Dive: Line-by-Line Thinking, Design Decisions, and Complete Code

**Project:** I2C Protocol RTL + UVM Verification Suite
**Protocol Reference:** NXP UM10204 Rev. 7.0 (I2C-bus specification and user manual)
**Target Tools:** EDA Playground (Xcelium / VCS), QuestaSim
**Estimated Duration:** Phases 1-3 (Days 1-6 of 20-day roadmap)
**Contents:** Complete thinking process behind every line of RTL and Testbench code

---

**DISCLAIMER:** This guide is designed to be extremely verbose. The goal is not brevity. The goal is to transfer every single design decision, every bug discovered, every line of code explained, and every "aha!" moment captured in writing. This is a reference for senior engineers mentoring juniors, and for juniors who want to understand the inner workings of protocol RTL design from scratch.

---

# TABLE OF CONTENTS FOR PHASES 1-3

**PART 1: PHASE 1 - PROTOCOL STUDY & SYSTEM ARCHITECTURE (DAYS 1-2)**
- 1.1 The Philosophy of Reading Before Coding
- 1.2 The Physical Bus: Open-Drain and Wired-AND
- 1.3 START, STOP, and Repeated START (Sr) Deep Dive
- 1.4 The Byte Frame: Address + ACK + Data + ACK
- 1.5 System Architecture: Block Diagram and Module Hierarchy
- 1.6 Register Interface Design (APB-like)
- 1.7 Directory Structure and Compilation Order

**PART 2: PHASE 2 - I2C MASTER RTL (DAYS 3-5)**
- File: `i2c_pkg.sv` (Lines 1-135) - Shared Types, Parameters, and Functions
- File: `i2c_master_controller.sv` (Lines 1-511) - The Core FSM Engine
- File: `i2c_master.sv` (Lines 1-57) - Top-Level Wrapper

**PART 3: PHASE 3 - I2C SLAVE RTL & TESTBENCH (DAYS 5-6)**
- File: `i2c_slave_controller.sv` (Lines 1-494) - Reactive State Machine
- File: `i2c_slave.sv` (Lines 1-61) - Top-Level Slave Wrapper
- File: `i2c_if.sv` (Lines 1-135) - SystemVerilog Interface
- File: `top_tb.sv` (Lines 1-128) - Top-Level Testbench

**PART 4: BUG LOG & LESSONS LEARNED**
- Bug #1 through Bug #10: Original code, broken behavior, root cause, and fix

---
---
