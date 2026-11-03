cmake_minimum_required(VERSION 3.16)
project(yshell_board C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# LVGL 9.2 defaults to LV_CONF_INCLUDE_SIMPLE; force our config explicitly,
# for the same reason as the host build (host/CMakeLists.txt).
set(LV_CONF_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/lv_conf.h")

add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../third_party/lvgl
                 ${CMAKE_BINARY_DIR}/lvgl)

file(GLOB_RECURSE UI_SOURCES CONFIGURE_DEPENDS
     ${CMAKE_CURRENT_SOURCE_DIR}/../ui/*.c)

find_package(Threads REQUIRED)

# ★ GPU 2D 单元：与 gpu1 比特流配对时才开（默认 OFF，交付 GUI 不变）。
option(YESHEN_GUI_GPU_UNIT "LVGL draw unit backed by the 2D GPU (needs DIRECT mode)" OFF)

add_executable(yshell
    ${UI_SOURCES}
    ${CMAKE_CURRENT_SOURCE_DIR}/../platform/gpu.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../platform/board_fb.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../platform/board_present.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../platform/board_touch.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../platform/input_uart.c)

target_include_directories(yshell PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../ui
    ${CMAKE_CURRENT_SOURCE_DIR}/../platform
    ${CMAKE_CURRENT_SOURCE_DIR}/../third_party
    # Peanut-GB (header-only) lives in the SoC repo; the embedded Game Boy
    # window links it straight into yshell.
    ${CMAKE_CURRENT_SOURCE_DIR}/../../VexiiYeshenLinux/sw/gb/peanut-gb)

target_link_libraries(yshell PRIVATE lvgl m Threads::Threads)

if(YESHEN_GUI_GPU_UNIT)
  target_sources(yshell PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../ui/gpu_draw_unit.c)
  target_compile_definitions(yshell PRIVATE YESHEN_GUI_GPU_UNIT=1)
endif()

# Phase R second-framebuffer A/B variant. OFF (default) keeps the freeze/bank
# app paired with the 7092e495 bitstream and images/sd_gui.img. Turn it ON only
# to build the app paired with the YeshenGuiRtl2 source-select bitstream and
# images/sd_gui2.img; never mix the two pairs.
option(BOARD_GUI_SECOND_BUF
       "GUI owns a second framebuffer at 0x9200_0000 (Phase R A/B variant)" OFF)

# VexiiYeshenLinux mainline variant (2026-10-30): the mainline RTL now has the
# same source-select protocol (VIDEO GUI_CTRL[0] = gui_src, GUI buffer at
# 0x9200_0000), but GUI_CTRL lives at window offset **0x09C** — 0x094 there is
# ETH_CTRL (H2 memory-read service). Implies the second-framebuffer code path.
# Pair it with the mainline `gui1` bitstream only.
option(BOARD_GUI_MAINLINE
       "App for the VexiiYeshenLinux mainline RTL (GUI_CTRL at 0x09C)" OFF)
if(BOARD_GUI_MAINLINE)
  set(BOARD_GUI_SECOND_BUF ON)
endif()

if(BOARD_GUI_SECOND_BUF)
  target_compile_definitions(yshell PRIVATE BOARD_GUI_SECOND_BUF=1)
endif()
if(BOARD_GUI_MAINLINE)
  target_compile_definitions(yshell PRIVATE
      BOARD_GUI_MAINLINE=1
      VIDEO_GUI_CTRL_OFF=0x49CUL)
endif()
