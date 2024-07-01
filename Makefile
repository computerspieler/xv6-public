include Makefile.toolchain

bin/%.c.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c -o $@ $<
	@$(OBJDUMP) -S $@ > $@.asm

bin/%.S.o: %.S
	@mkdir -p $(dir $@)
	$(CC) $(ASFLAGS) -c -o $@ $<

SRCS = kernel/entry.S $(filter-out kernel/entry.S kernel/vectors.S, $(wildcard kernel/*.S)) \
       $(wildcard kernel/*.c) kernel/vectors.S
OBJS = $(patsubst %,bin/%.o,$(filter-out kernel/memide.c, $(SRCS)))

bin/kernel.elf: $(OBJS) bin/entryother bin/initcode kernel/kernel.ld
	$(LD) $(LDFLAGS) -T kernel/kernel.ld -o $@ $(OBJS) -b binary bin/initcode bin/entryother
	$(OBJDUMP) -S $@ > $@.asm
	$(OBJDUMP) -t $@ | sed '1,/SYMBOL TABLE/d; s/ .* / /; /^$$/d' > $@.sym

bin/entryother: ASFLAGS=$(CFLAGS)
bin/entryother: $(patsubst %,bin/%.o,$(wildcard kernel/entry/*))
	$(LD) $(LDFLAGS) -N -e start -Ttext 0x7000 -o $@.o $<
	$(OBJCOPY) -S -O binary -j .text $@.o $@
	$(OBJDUMP) -S $@.o > $@.asm

bin/initcode: ASFLAGS=$(CFLAGS)
bin/initcode: $(patsubst %,bin/%.o,$(wildcard kernel/init/*))
	$(LD) $(LDFLAGS) -N -e start -Ttext 0 -o $@.out $^
	$(OBJCOPY) -S -O binary -j .text $@.out $@

bin/bootblock: ASFLAGS=$(CFLAGS)  -O -nostdinc
bin/bootblock: CFLAGS:=$(CFLAGS)  -O -nostdinc
bin/bootblock: AS=$(CC)
bin/bootblock: $(patsubst %,bin/%.o,$(wildcard kernel/boot/*))
	$(LD) $(LDFLAGS) -N -e start -Ttext 0x7C00 -o $@.o $^  
	$(OBJDUMP) -S $@.o > $@.asm
	$(OBJCOPY) -S -O binary -j .text $@.o $@
	./tools/sign.pl $@

kernel/vectors.S: tools/vectors.pl
	./tools/vectors.pl > $@

ULIB = $(patsubst %,bin/%.o,$(wildcard lib/*))

bin/user/%: bin/user/%.c.o $(ULIB)
	$(LD) $(LDFLAGS) -N -T linker.ld -o $@ $^
	$(OBJDUMP) -S $@ > bin/$*.asm
	$(OBJDUMP) -t $@ | sed '1,/SYMBOL TABLE/d; s/ .* / /; /^$$/d' > bin/$*.sym

bin/user/forktest: bin/user/forktest.c.o $(ULIB)
	# forktest has less library code linked in - needs to be small
	# in order to be able to max out the proc table.
	$(LD) $(LDFLAGS) -N -T linker.ld -o $@ $< bin/lib/ulib.c.o bin/lib/usys.S.o
	$(OBJDUMP) -S $@ > bin/$*.asm

tools/mkfs: tools/mkfs.c include/fs.h
	gcc -Werror -m32 -Wall -iquoteinclude -o $@ $<

UPROGS=$(patsubst %.c,bin/%,$(wildcard user/*.c))

fs.img: tools/mkfs README $(UPROGS)
	./tools/mkfs fs.img README $(UPROGS)

-include *.d

clean: 
	rm -rf *.tex *.dvi *.idx *.aux *.log *.ind *.ilg \
	*.d kernel/vectors.S bin xv6.img fs.img \
	bin/kernelmemfs xv6memfs.img tools/mkfs .gdbinit 

# run in emulators
# try to generate a unique GDB port
GDBPORT = $(shell expr `id -u` % 5000 + 25000)
# QEMU's gdb stub command line changed in 0.11
QEMUGDB = $(shell if $(QEMU) -help | grep -q '^-gdb'; \
	then echo "-gdb tcp::$(GDBPORT)"; \
	else echo "-s -p $(GDBPORT)"; fi)
ifndef CPUS
CPUS := 2
endif
QEMUOPTS = -drive file=fs.img,format=raw,if=ide,index=1,media=disk \
	-smp $(CPUS) -m 512M $(QEMUEXTRA)

qemu: bin/kernel.elf fs.img 
	$(QEMU) -kernel $< -serial mon:stdio $(QEMUOPTS)

qemu-nox: bin/kernel.elf fs.img
	$(QEMU) -kernel $< -nographic $(QEMUOPTS)

.gdbinit: .gdbinit.tmpl
	sed "s/localhost:1234/localhost:$(GDBPORT)/" < $^ > $@

qemu-gdb: bin/kernel.elf fs.img .gdbinit
	@echo "*** Now run 'gdb'." 1>&2
	$(QEMU) -kernel $< -serial mon:stdio $(QEMUOPTS) -S $(QEMUGDB)

qemu-nox-gdb: bin/kernel.elf fs.img .gdbinit
	@echo "*** Now run 'gdb'." 1>&2
	$(QEMU) -kernel $< -nographic $(QEMUOPTS) -S $(QEMUGDB)

