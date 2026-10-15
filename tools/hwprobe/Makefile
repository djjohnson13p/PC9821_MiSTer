TOOLS := gfxbenc2 gfxbench idelat ideprobe ioprobe irqwd opnapro pegcwatch probe2 sndtest memmap a20map d8bank integ

# Build the DOS .COM probe binaries from their assembly sources.
#
# A .COM is linked at 0x100 and objcopy emits .text with no padding. The
# binaries are NOT committed: `make` builds them, `make clean` removes them.
#
# Each tool lives in its own folder: <tool>/<tool>.s (the source), plus the
# optional <tool>_decode.py (a capture decoder) and RUN*.BAT (a DOS batch that
# runs the .COM on the machine). See README.md for what each probe measures.

# A DOS .COM is loaded at 0x100 in a 64 KiB segment, so its image must be at most
# 0x10000 - 0x100 = 65280 bytes. The toolchain does NOT catch an overflow: a padded
# probe2.s links and objcopy's to a 68074-byte "COM" with no error, and DOS simply
# refuses to load it - which would be discovered on the machine, after the trip.
# probe2 is the file several lanes append to and it has ~1.3 KiB of headroom, so the
# limit is enforced here, once, for every tool.
COM_MAX := 65280

# THE DOS-LEGAL NAME OF EACH TOOL'S .COM, where it differs from the tool's own name. DOS 8.3 gives
# a filename stem EIGHT characters, and PEGCWATCH is nine - so a DOS filesystem cannot hold
# `PEGCWATCH.COM` at all, which meant the probe could not be copied to the machine, let alone
# loaded. The tool's DIRECTORY stays `pegcwatch/` so the decoder's path
# (`tools/hwprobe/pegcwatch/pegcwatch_decode.py`) and every citation of it stay valid; only the
# built file is renamed. Nothing else changes: the rows the probe PRINTS still begin `PEGCWATCH`,
# and the decoder parses those, not the filename.
COM_NAME_pegcwatch := pegcw

com_name = $(if $(COM_NAME_$(1)),$(COM_NAME_$(1)),$(1))

.DEFAULT_GOAL := all
.PHONY: all clean

all: $(foreach t,$(TOOLS),$(t)/$(call com_name,$(t)).com)

# One .COM per tool: as -> ld -> objcopy.
define build_com
$(1)/$(call com_name,$(1)).com: $(1)/$(1).s
	as --32 -o $(1)/$(1).o $$<
	ld -m elf_i386 -Ttext 0x100 -e 0x100 -o $(1)/$(1).elf $(1)/$(1).o
	objcopy -O binary -j .text $(1)/$(1).elf $$@
	@if [ `wc -c < $$@` -gt $(COM_MAX) ]; then \
	  echo "ERROR: $$@ is `wc -c < $$@` bytes - over the $(COM_MAX)-byte DOS .COM limit"; \
	  echo "       (a .COM loads at 0x100 in a 64 KiB segment; split the tool or move data out)"; \
	  rm -f $$@; exit 1; fi
	rm -f $(1)/$(1).o $(1)/$(1).elf
	@echo "built $$@"
endef

$(foreach t,$(TOOLS),$(eval $(call build_com,$(t))))

clean:
	rm -f $(foreach t,$(TOOLS),$(t)/$(t).com $(t)/$(call com_name,$(t)).com $(t)/$(t).o $(t)/$(t).elf)
