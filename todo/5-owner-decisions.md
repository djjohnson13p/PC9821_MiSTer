# 5. Owner decisions

Blocked on a maintainer decision, not on work.

53. **z486 reset-state divergences.** **DECISION (OWNER).** `CR0` resets to `0x00000010` where
    the datasheet says `0x60000010`; `idt_limit`/`gdt_limit` reset to `0x003FF` where the
    datasheet says `0xFFFF`. The CR0 half is a z486 parameter, `RESET_CACHE_DISABLED` (0 = the
    historical value, which this platform uses; 1 = architectural CD=NW=1, and the CPU honours
    CD/NW). Before choosing 1, confirm what CR0 the ITF leaves at the DOS prompt. The descriptor
    limit half would be a change in the z486 fork (`segmentation_unit.sv`) plus a passing z486
    suite. **Decision:** the parameter value, and whether to change the limits.

56. **HELP key held through boot.** **DECISION (OWNER).** The framework never reports a key that
    is already down when the core starts, and the core does not synthesise one, so holding HELP
    through a boot (the PC-98's SETUP entry) produces no event. **Decision:** add an OSD option /
    synthesise the event, or document it as a limitation.
