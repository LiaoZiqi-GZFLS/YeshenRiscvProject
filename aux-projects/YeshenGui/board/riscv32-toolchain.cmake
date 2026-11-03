set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR riscv32)

# The compiler actually installed in this workspace is the 32-bit buildroot
# toolchain. The plan originally named riscv64-buildroot-linux-uclibc-gcc,
# which does not exist here; do not silently fall back to it (or to host gcc).
set(RV32_CC_DEFAULT
    "$ENV{HOME}/vexii-build/buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-gcc")

if(DEFINED ENV{YSHELL_RV32_CC} AND NOT "$ENV{YSHELL_RV32_CC}" STREQUAL "")
  set(RV32_CC "$ENV{YSHELL_RV32_CC}")
else()
  set(RV32_CC "${RV32_CC_DEFAULT}")
endif()

if(NOT EXISTS "${RV32_CC}")
  message(FATAL_ERROR
      "RV32 cross compiler not found: ${RV32_CC}\n"
      "Expected the buildroot riscv32 toolchain at ${RV32_CC_DEFAULT}.\n"
      "Set YSHELL_RV32_CC to an existing riscv32 GNU compiler (not riscv64, not host gcc).")
endif()

set(CMAKE_C_COMPILER "${RV32_CC}" CACHE FILEPATH "RV32 cross compiler")
set(CMAKE_C_FLAGS "-O2 -march=rv32imac -mabi=ilp32 -static")
set(CMAKE_EXE_LINKER_FLAGS "-static")
