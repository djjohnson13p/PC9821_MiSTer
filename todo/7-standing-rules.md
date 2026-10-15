# 7. Standing engineering rules this list must respect

* Evidence order: real hardware captures > the real machine > NP2kai > qemu-pc98 > MAME/ymfm >
  ReC98. For a chip's internals the die-shot model (YM2608-LLE for the OPNA) outranks the
  behavioural ones. Our own RTL and benches are never evidence of what the hardware does.
* Fail-first benches: the expected value comes from the capture or the reference, never from
  our RTL.
* One clamp at the authentic junction: the FM+ADPCM sum clamps once at `jt08_acc` (the YM2608B
  output shifter rails at +-32768). The six-drum bus is the die's 16-bit two's-complement wrap,
  not a wide sum. The SSG is not in that junction; it joins zero-mean through the board's
  coupling (the DC block).
* The read-back side is the systematic weak spot: when touching a device, verify its READ
  ports, not only writes.
* Comments carry hardware facts and external assumptions with their citations, not narration.
* Never delete a seed sweep's `output_files/`; clean only the `seedNNN/tree/` scratch copies.
