# I2C Project — Learnings Folder

This folder captures **session-by-session deep-dive notes** from mentor walkthroughs of the I2C verification project.

## Purpose

Each file documents:
- The **module/concept** being studied
- **Architectural understanding** (what + why)
- **Quiz Q&A** with honest scoring
- **Senior-engineer-grade answers** to each question (the answer NVIDIA/Qualcomm/Intel interview panels want to hear)
- **Interview traps and gotchas** specific to the concept
- **Action items** for follow-up

## How to use this folder

1. Read each `NN_*.md` file in numerical order.
2. After reading, **close the file** and try to answer the quiz questions out loud, as if in an interview.
3. If you get stuck, re-read. Repeat until the answers are reflexive.
4. Whenever you find a gap in your understanding, add it to `gaps.md` (create when needed).

## File index

| File | Topic | Status |
|---|---|---|
| [01_i2c_pkg_walkthrough.md](./01_i2c_pkg_walkthrough.md) | I2C Package — vocabulary, params, enums, functions, include guards | ✅ Complete |
| _Coming next_ | i2c_master.sv — thin wrapper module | ⏳ Pending |
| _Coming next_ | i2c_master_controller.sv — master FSM deep-dive | ⏳ Pending |
| _Coming next_ | i2c_slave.sv + i2c_slave_controller.sv | ⏳ Pending |
| _Coming next_ | UVM testbench walkthrough (uvm/ folder) | ⏳ Pending |

## Mentor-mode protocol (how these sessions run)

1. Mentor explains a module/concept top-down (architecture → details).
2. Mentor asks 5-10 quiz questions.
3. Student answers honestly — **"I don't know" is acceptable and preferred over bluffing.**
4. Mentor scores each answer, gives the senior-engineer-grade answer.
5. Notes are committed here for permanent reference.

**Why this matters:** The point isn't to "finish" the project. The point is to be able to **articulate every line** in an interview. Verification engineers are hired for clarity of thought, not for having a fancy GitHub repo.
