subdir-y += acpi
subdir-y += cpu
subdir-y += genapic
subdir-$(CONFIG_XEN_GUEST) += guest
subdir-$(CONFIG_HVM) += hvm
subdir-y += mm
subdir-$(CONFIG_XENOPROF) += oprofile
subdir-$(CONFIG_PV) += pv
subdir-y += x86_64

alternative-y := alternative.init.o
alternative-$(CONFIG_LIVEPATCH) :=
obj-bin-y += $(alternative-y)
obj-y += apic.o
obj-y += bitops.o
obj-bin-y += bzimage.init.o
obj-bin-y += clear_page.o
obj-bin-y += copy_page.o
obj-y += cpuid.o
obj-y += compat.o x86_64/compat.o
obj-$(CONFIG_KEXEC) += crash.o
obj-y += debug.o
obj-y += delay.o
obj-bin-y += dmi_scan.init.o
obj-y += domctl.o
obj-y += domain.o
obj-bin-y += dom0_build.init.o
obj-y += domain_page.o
obj-y += e820.o
obj-y += extable.o
obj-y += flushtlb.o
obj-$(CONFIG_CRASH_DEBUG) += gdbstub.o
obj-y += hypercall.o
obj-y += i387.o
obj-y += i8259.o
obj-y += io_apic.o
obj-$(CONFIG_LIVEPATCH) += alternative.o livepatch.o
obj-y += msi.o
obj-y += msr.o
obj-$(CONFIG_INDIRECT_THUNK) += indirect-thunk.o
obj-y += ioport_emulate.o
obj-y += irq.o
obj-$(CONFIG_KEXEC) += machine_kexec.o
obj-y += microcode_amd.o
obj-y += microcode_intel.o
obj-y += microcode.o
obj-y += mm.o x86_64/mm.o
obj-y += monitor.o
obj-y += mpparse.o
obj-y += nmi.o
obj-y += numa.o
obj-y += pci.o
obj-y += percpu.o
obj-y += physdev.o x86_64/physdev.o
obj-y += platform_hypercall.o x86_64/platform_hypercall.o
obj-y += psr.o
obj-y += setup.o
obj-y += shutdown.o
obj-y += smp.o
obj-y += smpboot.o
obj-y += spec_ctrl.o
obj-y += srat.o
obj-y += string.o
obj-y += sysctl.o
obj-y += time.o
obj-y += trace.o
obj-y += traps.o
obj-y += tsx.o
obj-y += usercopy.o
obj-y += x86_emulate.o
obj-$(CONFIG_TBOOT) += tboot.o
obj-y += hpet.o
obj-y += vm_event.o
obj-y += xstate.o

x86_emulate.o: x86_emulate/x86_emulate.c x86_emulate/x86_emulate.h

efi-y := $(shell if [ ! -r $(BASEDIR)/include/xen/compile.h -o \
                      -O $(BASEDIR)/include/xen/compile.h ]; then \
                         echo '$(TARGET).efi'; fi)

ifneq ($(build_id_linker),)
notes_phdrs = --notes
else
ifeq ($(CONFIG_PVH_GUEST),y)
notes_phdrs = --notes
endif
endif

ifdef CONFIG_LIVEPATCH
all_symbols = --all-symbols
ifdef CONFIG_FAST_SYMBOL_LOOKUP
all_symbols = --all-symbols --sort-by-name
endif
else
all_symbols =
endif

syms-warn-dup-y := --warn-dup
syms-warn-dup-$(CONFIG_SUPPRESS_DUPLICATE_SYMBOL_WARNINGS) :=

$(TARGET): $(TARGET)-syms $(efi-y) boot/mkelf32
	./boot/mkelf32 $(notes_phdrs) $(TARGET)-syms $(TARGET) $(XEN_IMG_OFFSET) \
	               `$(NM) $(TARGET)-syms | sed -ne 's/^\([^ ]*\) . __2M_rwdata_end$$/0x\1/p'`

ALL_OBJS := $(BASEDIR)/arch/x86/boot/built_in.o $(BASEDIR)/arch/x86/efi/built_in.o $(ALL_OBJS)

ifeq ($(CONFIG_LTO),y)
# Gather all LTO objects together
prelink_lto.o: $(ALL_OBJS)
	$(LD_LTO) -r -o $@ $^

prelink-efi_lto.o: $(ALL_OBJS) efi/runtime.o efi/compat.o
	$(guard) $(LD_LTO) -r -o $@ $(filter-out %/efi/built_in.o,$^)

# Link it with all the binary objects
prelink.o: $(patsubst %/built_in.o,%/built_in_bin.o,$(ALL_OBJS)) prelink_lto.o
	$(LD) $(LDFLAGS) -r -o $@ $^

prelink-efi.o: $(patsubst %/built_in.o,%/built_in_bin.o,$(ALL_OBJS)) prelink-efi_lto.o efi/boot.init.o
	$(guard) $(LD) $(LDFLAGS) -r -o $@ $^
else
prelink.o: $(ALL_OBJS)
	$(LD) $(LDFLAGS) -r -o $@ $^

prelink-efi.o: $(ALL_OBJS) efi/boot.init.o efi/runtime.o efi/compat.o
	$(guard) $(LD) $(LDFLAGS) -r -o $@ $(filter-out %/efi/built_in.o,$^)
endif

$(BASEDIR)/common/symbols-dummy.o:
	$(MAKE) -f $(BASEDIR)/Rules.mk -C $(BASEDIR)/common symbols-dummy.o

$(TARGET)-syms: prelink.o xen.lds $(BASEDIR)/common/symbols-dummy.o
	$(LD) $(LDFLAGS) -T xen.lds -N prelink.o $(build_id_linker) \
	    $(BASEDIR)/common/symbols-dummy.o -o $(@D)/.$(@F).0
	$(NM) -pa --format=sysv $(@D)/.$(@F).0 \
		| $(BASEDIR)/tools/symbols $(all_symbols) --sysv --sort \
		>$(@D)/.$(@F).0.S
	$(MAKE) -f $(BASEDIR)/Rules.mk $(@D)/.$(@F).0.o
	$(LD) $(LDFLAGS) -T xen.lds -N prelink.o $(build_id_linker) \
	    $(@D)/.$(@F).0.o -o $(@D)/.$(@F).1
	$(NM) -pa --format=sysv $(@D)/.$(@F).1 \
		| $(BASEDIR)/tools/symbols $(all_symbols) --sysv --sort $(syms-warn-dup-y) \
		>$(@D)/.$(@F).1.S
	$(MAKE) -f $(BASEDIR)/Rules.mk $(@D)/.$(@F).1.o
	$(LD) $(LDFLAGS) -T xen.lds -N prelink.o $(build_id_linker) \
	    $(@D)/.$(@F).1.o -o $@
	$(NM) -pa --format=sysv $(@D)/$(@F) \
		| $(BASEDIR)/tools/symbols --xensyms --sysv --sort \
		>$(@D)/$(@F).map
	rm -f $(@D)/.$(@F).[0-9]* $(@D)/..$(@F).[0-9]*

note.o: $(TARGET)-syms
	$(OBJCOPY) -O binary --only-section=.note.gnu.build-id  $(BASEDIR)/xen-syms $@.bin
	$(OBJCOPY) -I binary -O elf64-x86-64 -B i386:x86-64 \
		--rename-section=.data=.note.gnu.build-id -S $@.bin $@
	rm -f $@.bin

EFI_LDFLAGS = $(patsubst -m%,-mi386pep,$(LDFLAGS)) --subsystem=10
EFI_LDFLAGS += --image-base=$(1) --stack=0,0 --heap=0,0 --strip-debug
EFI_LDFLAGS += --section-alignment=0x200000 --file-alignment=0x20
EFI_LDFLAGS += --major-image-version=$(XEN_VERSION)
EFI_LDFLAGS += --minor-image-version=$(XEN_SUBVERSION)
EFI_LDFLAGS += --major-os-version=2 --minor-os-version=0
EFI_LDFLAGS += --major-subsystem-version=2 --minor-subsystem-version=0

# Check if the compiler supports the MS ABI.
export XEN_BUILD_EFI := $(shell $(CC) $(filter-out $(CFLAGS-y) .%.d,$(CFLAGS)) -c efi/check.c -o efi/check.o 2>/dev/null && echo y)
# Check if the linker supports PE.
XEN_BUILD_PE := $(if $(XEN_BUILD_EFI),$(shell $(LD) -mi386pep --subsystem=10 -o efi/check.efi efi/check.o 2>/dev/null && echo y))
CFLAGS-$(XEN_BUILD_EFI) += -DXEN_BUILD_EFI

$(TARGET).efi: VIRT_BASE = 0x$(shell $(NM) efi/relocs-dummy.o | sed -n 's, A VIRT_START$$,,p')
$(TARGET).efi: ALT_BASE = 0x$(shell $(NM) efi/relocs-dummy.o | sed -n 's, A ALT_START$$,,p')
# Don't use $(wildcard ...) here - at least make 3.80 expands this too early!
$(TARGET).efi: guard = $(if $(filter y,$(XEN_BUILD_PE)),,:)

ifneq ($(build_id_linker),)
ifeq ($(call ld-ver-build-id,$(LD) $(filter -m%,$(EFI_LDFLAGS))),y)
CFLAGS += -DBUILD_ID_EFI
EFI_LDFLAGS += $(build_id_linker)
note_file := efi/buildid.o
else
note_file := note.o
endif
else
note_file :=
endif

$(TARGET).efi: prelink-efi.o $(note_file) efi.lds efi/relocs-dummy.o $(BASEDIR)/common/symbols-dummy.o efi/mkreloc
	$(foreach base, $(VIRT_BASE) $(ALT_BASE), \
	          $(guard) $(LD) $(call EFI_LDFLAGS,$(base)) -T efi.lds -N $< efi/relocs-dummy.o \
	                $(BASEDIR)/common/symbols-dummy.o $(note_file) -o $(@D)/.$(@F).$(base).0 &&) :
	$(guard) efi/mkreloc $(foreach base,$(VIRT_BASE) $(ALT_BASE),$(@D)/.$(@F).$(base).0) >$(@D)/.$(@F).0r.S
	$(guard) $(NM) -pa --format=sysv $(@D)/.$(@F).$(VIRT_BASE).0 \
		| $(guard) $(BASEDIR)/tools/symbols $(all_symbols) --sysv --sort >$(@D)/.$(@F).0s.S
	$(guard) $(MAKE) -f $(BASEDIR)/Rules.mk $(@D)/.$(@F).0r.o $(@D)/.$(@F).0s.o
	$(foreach base, $(VIRT_BASE) $(ALT_BASE), \
	          $(guard) $(LD) $(call EFI_LDFLAGS,$(base)) -T efi.lds -N $< \
	                $(@D)/.$(@F).0r.o $(@D)/.$(@F).0s.o $(note_file) -o $(@D)/.$(@F).$(base).1 &&) :
	$(guard) efi/mkreloc $(foreach base,$(VIRT_BASE) $(ALT_BASE),$(@D)/.$(@F).$(base).1) >$(@D)/.$(@F).1r.S
	$(guard) $(NM) -pa --format=sysv $(@D)/.$(@F).$(VIRT_BASE).1 \
		| $(guard) $(BASEDIR)/tools/symbols $(all_symbols) --sysv --sort >$(@D)/.$(@F).1s.S
	$(guard) $(MAKE) -f $(BASEDIR)/Rules.mk $(@D)/.$(@F).1r.o $(@D)/.$(@F).1s.o
	$(guard) $(LD) $(call EFI_LDFLAGS,$(VIRT_BASE)) -T efi.lds -N $< \
	                $(@D)/.$(@F).1r.o $(@D)/.$(@F).1s.o $(note_file) -o $@
	if $(guard) false; then rm -f $@; echo 'EFI support disabled'; \
	else $(NM) -pa --format=sysv $(@D)/$(@F) \
		| $(BASEDIR)/tools/symbols --xensyms --sysv --sort >$(@D)/$(@F).map; fi
	rm -f $(@D)/.$(@F).[0-9]* $(@D)/..$(@F).[0-9]*

efi/boot.init.o efi/runtime.o efi/compat.o efi/buildid.o: $(BASEDIR)/arch/x86/efi/built_in.o
efi/boot.init.o efi/runtime.o efi/compat.o efi/buildid.o: ;

asm-offsets.s: $(TARGET_SUBARCH)/asm-offsets.c
	$(CC) $(filter-out -flto,$(CFLAGS)) -S -o $@ $<

xen.lds: xen.lds.S
	$(CC) -P -E -Ui386 $(AFLAGS) -o $@ $<
	sed -e 's/xen\.lds\.o:/xen\.lds:/g' <.xen.lds.d >.xen.lds.d.new
	mv -f .xen.lds.d.new .xen.lds.d

efi.lds: xen.lds.S
	$(CC) -P -E -Ui386 -DEFI $(AFLAGS) -o $@ $<
	sed -e 's/efi\.lds\.o:/efi\.lds:/g' <.$(@F).d >.$(@F).d.new
	mv -f .$(@F).d.new .$(@F).d

boot/mkelf32: boot/mkelf32.c
	$(HOSTCC) $(HOSTCFLAGS) -o $@ $<

efi/mkreloc: efi/mkreloc.c
	$(HOSTCC) $(HOSTCFLAGS) -g -o $@ $<

.PHONY: clean
clean::
	rm -f asm-offsets.s *.lds boot/*.o boot/*~ boot/core boot/mkelf32
	rm -f $(BASEDIR)/.xen-syms.[0-9]* boot/.*.d
	rm -f $(BASEDIR)/.xen.efi.[0-9]* efi/*.efi efi/mkreloc
	rm -f boot/cmdline.S boot/reloc.S boot/*.lnk boot/*.bin
	rm -f note.o

# Suppress loading of DEPS files for internal, temporary target files.  This
# then also suppresses re-generation of the respective .*.d2 files.
ifeq ($(filter-out .xen%.o,$(notdir $(MAKECMDGOALS))),)
DEPS:=
endif
