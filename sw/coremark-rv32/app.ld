OUTPUT_ARCH( "riscv" )
ENTRY( _start )

/* Bare-metal at the core's reset vector (0x80000000), straight into DDR.  The image is what the
   UART loader writes; everything past the loaded image (.bss, stack) is created at runtime. */
MEMORY
{
  ram (wxai!r) : ORIGIN = 0x80000000, LENGTH = 8M
}

SECTIONS
{
  .init : { KEEP(*(SORT_NONE(.init))) } >ram
  .text : { *(.text.unlikely .text.unlikely.*) *(.text .text.*) *(.gnu.linkonce.t.*) } >ram

  . = ALIGN(8);
  _data_lma = .;
  _data = .;
  .data : {
    *(.rdata) *(.rodata .rodata.*) *(.gnu.linkonce.r.*)
    *(.data .data.*) *(.gnu.linkonce.d.*)
    . = ALIGN(8);
    __global_pointer$ = . + 0x800;
    *(.srodata .srodata.*)
    *(.sdata .sdata.*) *(.gnu.linkonce.s.*)
    . = ALIGN(8);
  } >ram
  _edata = .;
  PROVIDE(edata = .);

  __bss_start = .;
  PROVIDE(_fbss = .);
  .bss : {
    *(.sbss .sbss.*) *(.sgnu.linkonce.sb.*)
    *(.bss .bss.*) *(.gnu.linkonce.b.*) *(COMMON)
    . = ALIGN(8);
  } >ram
  _end = .;
  PROVIDE(end = .);

  /* Stack at the very top of the reserved region, growing down towards .bss. */
  _sp = ORIGIN(ram) + LENGTH(ram) - 16;
}
