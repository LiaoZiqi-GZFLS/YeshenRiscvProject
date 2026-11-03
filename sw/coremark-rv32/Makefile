# CoreMark for VexiiYeshenLinux (PG2L200H, VexiiRiscv RV32, bare metal at 0x80000000).
# Build (WSL):  make ITERS=10          ->  coremark.bin  (load it to 0x80000000, then send 'J')
CROSS   ?= riscv64-unknown-elf-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump

PORT  := port
MARCH := rv32imac_zicsr
MABI  := ilp32
ITERS ?= 10

CFLAGS := -O3 -fno-common -funroll-loops -finline-functions -falign-functions=16 \
          -falign-jumps=4 -falign-loops=4 -finline-limit=1000 -fno-if-conversion2 \
          -fno-crossjumping -freorder-blocks-and-partition -ffreestanding \
          -march=$(MARCH) -mabi=$(MABI) -mcmodel=medany \
          -DPERFORMANCE_RUN=1 -DITERATIONS=$(ITERS) \
          -I. -I$(PORT) -DFLAGS_STR='"-O3 rv32imac_zicsr/ilp32"' -Wall

LDSCRIPT := app.ld
LDLIBS   := -nostdlib -Wl,-Map,coremark.map,--print-memory-usage -T$(LDSCRIPT) -lgcc

SRCS := core_list_join.c core_main.c core_matrix.c core_state.c core_util.c \
        $(PORT)/core_portme.c $(PORT)/mini_libc.c ee_printf.c cvt.c start.S
OBJS := $(SRCS:.c=.o)
OBJS := $(OBJS:.S=.o)

all: coremark.bin

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

%.o: %.S
	$(CC) $(CFLAGS) -c $< -o $@

coremark.elf: $(OBJS) $(LDSCRIPT)
	$(CC) $(CFLAGS) $(OBJS) $(LDLIBS) -o $@

coremark.bin: coremark.elf
	$(OBJCOPY) -O binary $< $@
	@ls -l $@

dis: coremark.elf
	$(OBJDUMP) -d $< | head -80

clean:
	rm -f $(OBJS) coremark.elf coremark.bin coremark.map

.PHONY: all clean dis
