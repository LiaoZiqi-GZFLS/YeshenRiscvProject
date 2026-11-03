cmake_minimum_required(VERSION 3.16)
project(yshell_host C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)
pkg_check_modules(SDL2 REQUIRED sdl2)

# LVGL 9.2's custom.cmake enables LV_CONF_INCLUDE_SIMPLE by default, which
# makes "lv_conf.h" resolve only against LVGL's own include paths. Point it
# at the plan's third_party/lv_conf.h explicitly.
set(LV_CONF_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/lv_conf.h")

add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../third_party/lvgl
                 ${CMAKE_BINARY_DIR}/lvgl)

file(GLOB_RECURSE UI_SOURCES CONFIGURE_DEPENDS
     ${CMAKE_CURRENT_SOURCE_DIR}/../ui/*.c)

add_executable(yshell_host
    ${UI_SOURCES}
    ${CMAKE_CURRENT_SOURCE_DIR}/../platform/host_sdl.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../platform/gpu.c)

# GPU 驱动的单元闸门（主机侧模拟）：重放 VexiiYeshenLinux 的六个 2D 黄金用例。
add_executable(gpu_host_test
    ${CMAKE_CURRENT_SOURCE_DIR}/../tests/gpu_host_test.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../platform/gpu.c)
target_include_directories(gpu_host_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../platform)
target_compile_definitions(gpu_host_test PRIVATE UI_HOST=1)

# LVGL draw unit 的 A/B 闸门（同一场景 SW vs GPU 逐字节比对）。
# 注意：ui/*.c 被 GLOB 进了 yshell_host；本目标只挑 GPU 单元与测试自身的源文件。
add_executable(gpu_unit_host_test
    ${CMAKE_CURRENT_SOURCE_DIR}/../tests/gpu_unit_host_test.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../ui/gpu_draw_unit.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../platform/gpu.c)
target_include_directories(gpu_unit_host_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../ui
    ${CMAKE_CURRENT_SOURCE_DIR}/../platform
    ${CMAKE_CURRENT_SOURCE_DIR}/../third_party)
target_compile_definitions(gpu_unit_host_test PRIVATE
    UI_HOST=1 YESHEN_GUI_GPU_UNIT=1)
target_link_libraries(gpu_unit_host_test PRIVATE lvgl m)

target_include_directories(yshell_host PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../ui
    ${CMAKE_CURRENT_SOURCE_DIR}/../platform
    ${CMAKE_CURRENT_SOURCE_DIR}/../third_party
    ${CMAKE_CURRENT_SOURCE_DIR}/../../VexiiYeshenLinux/sw/gb/peanut-gb
    ${SDL2_INCLUDE_DIRS})

target_compile_options(yshell_host PRIVATE ${SDL2_CFLAGS_OTHER})
target_compile_definitions(yshell_host PRIVATE UI_HOST=1)

# ★ GPU 2D 单元（DIRECT 模式 + 实心矩形走硬件）。默认 OFF：交付的 GUI 仍走
# PARTIAL + platform_flush。ON 时配对 gpu1 比特流使用。
option(YESHEN_GUI_GPU_UNIT "LVGL draw unit backed by the 2D GPU (needs DIRECT mode)" OFF)
if(YESHEN_GUI_GPU_UNIT)
  target_sources(yshell_host PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../ui/gpu_draw_unit.c)
  target_compile_definitions(yshell_host PRIVATE YESHEN_GUI_GPU_UNIT=1)
endif()
target_link_directories(yshell_host PRIVATE ${SDL2_LIBRARY_DIRS})
target_link_libraries(yshell_host PRIVATE lvgl ${SDL2_LIBRARIES} m)
