AS      = $(TOOLCHAIN_PREFIX)as
AR      = $(TOOLCHAIN_PREFIX)ar
CC      = $(TOOLCHAIN_PREFIX)gcc
CXX     = $(TOOLCHAIN_PREFIX)g++
LD      = $(TOOLCHAIN_PREFIX)ld
NM      = $(TOOLCHAIN_PREFIX)nm
STRIP   = $(TOOLCHAIN_PREFIX)strip
OBJCOPY = $(TOOLCHAIN_PREFIX)objcopy
OBJDUMP = $(TOOLCHAIN_PREFIX)objdump

CPPFLAGS := -I${CURDIR}

CFLAGS   := -Wall -fPIC
CFLAGS   += $(CPPFLAGS)

CXXFLAGS := -Wall --std=c++11 -fPIC
CXXFLAGS += $(CPPFLAGS)

export AS AR CC CXX LD NM STRIP OBJCOPY OBJDUMP
export CFLAGS CXXFLAGS

.PHONY: build
build:
	$(MAKE) -C ${KERNEL_DEV_PATH} M=${CURDIR}/hvx ARCH=arm64 modules
	$(MAKE) -C vmi

.PHONY: clean
clean:
	$(MAKE) -C ${KERNEL_DEV_PATH} M=${CURDIR}/hvx ARCH=arm64 clean
	$(MAKE) -C vmi clean
