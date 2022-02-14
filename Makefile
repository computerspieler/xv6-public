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
MEMFSOBJS = $(patsubst %,bin/%.o,$(filter-out kernel/ide.c, $(SRCS)))

xv6.img: bin/bootblock bin/kernel.elf
	dd if=/dev/zero of=$@ count=10000
	dd if=bin/bootblock of=$@ conv=notrunc
	dd if=bin/kernel.elf of=$@ seek=1 conv=notrunc

xv6memfs.img: bin/bootblock bin/kernelmemfs.elf
	dd if=/dev/zero of=$@ count=10000
	dd if=bin/bootblock of=$@ conv=notrunc
	dd if=bin/kernelmemfs.elf of=$@ seek=1 conv=notrunc

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


# bin/kernelmemfs is a copy of kernel that maintains the
# disk image in memory instead of writing to a disk.
# This is not so useful for testing persistent storage or
# exploring disk buffering implementations, but it is
# great for testing the kernel on real hardware without
# needing a scratch disk.
bin/kernelmemfs.elf: $(MEMFSOBJS) bin/entryother bin/initcode kernel/kernel.ld fs.img
	$(LD) $(LDFLAGS) -T kernel/kernel.ld -o $@ $(MEMFSOBJS) -b binary bin/initcode bin/entryother fs.img
	$(OBJDUMP) -S $@ > $@.asm
	$(OBJDUMP) -t $@ | sed '1,/SYMBOL TABLE/d; s/ .* / /; /^$$/d' > $@.sym

kernel/vectors.S: tools/vectors.pl
	./tools/vectors.pl > $@

ULIB = $(patsubst %,bin/%.o,$(wildcard lib/*))

bin/_%: bin/user/%.c.o $(ULIB)
	$(LD) $(LDFLAGS) -N -e main -Ttext 0 -o $@ $^
	$(OBJDUMP) -S $@ > bin/$*.asm
	$(OBJDUMP) -t $@ | sed '1,/SYMBOL TABLE/d; s/ .* / /; /^$$/d' > bin/$*.sym

bin/_forktest: bin/user/forktest.c.o $(ULIB)
	# forktest has less library code linked in - needs to be small
	# in order to be able to max out the proc table.
	$(LD) $(LDFLAGS) -N -e main -Ttext 0 -o $@ $< bin/lib/ulib.c.o bin/lib/usys.S.o
	$(OBJDUMP) -S $@ > bin/$*.asm

tools/mkfs: tools/mkfs.c include/fs.h
	gcc -Werror -Wall -iquoteinclude -o $@ $<

# Prevent deletion of intermediate files, e.g. cat.o, after first build, so
# that disk image changes after first build are persistent until clean.  More
# details:
# http://www.gnu.org/software/make/manual/html_node/Chained-Rules.html
.PRECIOUS: %.o

UPROGS=$(patsubst user/%.c,bin/_%,$(wildcard user/*.c))

fs.img: tools/mkfs README $(UPROGS)
	./tools/mkfs fs.img README $(UPROGS)

-include *.d

clean: 
	rm -rf *.tex *.dvi *.idx *.aux *.log *.ind *.ilg \
	*.d kernel/vectors.S bin xv6.img fs.img \
	bin/kernelmemfs xv6memfs.img tools/mkfs .gdbinit 

# run in emulators

bochs : fs.img xv6.img
	if [ ! -e .bochsrc ]; then ln -s dot-bochsrc .bochsrc; fi
	bochs -q

# try to generate a unique GDB port
GDBPORT = $(shell expr `id -u` % 5000 + 25000)
# QEMU's gdb stub command line changed in 0.11
QEMUGDB = $(shell if $(QEMU) -help | grep -q '^-gdb'; \
	then echo "-gdb tcp::$(GDBPORT)"; \
	else echo "-s -p $(GDBPORT)"; fi)
ifndef CPUS
CPUS := 2
endif
QEMUOPTS = -drive file=fs.img,index=1,media=disk,format=raw -drive file=xv6.img,index=0,media=disk,format=raw -smp $(CPUS) -m 512 $(QEMUEXTRA)

qemu: fs.img xv6.img
	$(QEMU) -serial mon:stdio $(QEMUOPTS)

qemu-memfs: xv6memfs.img
	$(QEMU) -drive file=xv6memfs.img,index=0,media=disk,format=raw -smp $(CPUS) -m 256

qemu-nox: fs.img xv6.img
	$(QEMU) -nographic $(QEMUOPTS)

.gdbinit: .gdbinit.tmpl
	sed "s/localhost:1234/localhost:$(GDBPORT)/" < $^ > $@

qemu-gdb: fs.img xv6.img .gdbinit
	@echo "*** Now run 'gdb'." 1>&2
	$(QEMU) -serial mon:stdio $(QEMUOPTS) -S $(QEMUGDB)

qemu-nox-gdb: fs.img xv6.img .gdbinit
	@echo "*** Now run 'gdb'." 1>&2
	$(QEMU) -nographic $(QEMUOPTS) -S $(QEMUGDB)

# CUT HERE
# prepare dist for students
# after running make dist, probably want to
# rename it to rev0 or rev1 or so on and then
# check in that version.

EXTRA=\
	mkfs.c ulib.c user.h cat.c echo.c forktest.c grep.c kill.c\
	ln.c ls.c mkdir.c rm.c stressfs.c usertests.c wc.c zombie.c\
	printf.c umalloc.c\
	README dot-bochsrc *.pl toc.* runoff runoff1 runoff.list\
	.gdbinit.tmpl gdbutil\

dist:
	rm -rf dist
	mkdir dist
	for i in $(FILES); \
	do \
		grep -v PAGEBREAK $$i >dist/$$i; \
	done
	sed '/CUT HERE/,$$d' Makefile >dist/Makefile
	echo >dist/runoff.spec
	cp $(EXTRA) dist

dist-test:
	rm -rf dist
	make dist
	rm -rf dist-test
	mkdir dist-test
	cp dist/* dist-test
	cd dist-test; $(MAKE) print
	cd dist-test; $(MAKE) bochs || true
	cd dist-test; $(MAKE) qemu

# update this rule (change rev#) when it is time to
# make a new revision.
tar:
	rm -rf /tmp/xv6
	mkdir -p /tmp/xv6
	cp dist/* dist/.gdbinit.tmpl /tmp/xv6
	(cd /tmp; tar cf - xv6) | gzip >xv6-rev10.tar.gz  # the next one will be 10 (9/17)

.PHONY: dist-test dist
