#!/usr/bin/env bash
# z486's OWN Verilator suite, run against the PATCHED submodule.
#
# The rest of this gate measures the CPU through the PC-98 fabric: one end-to-end
# verdict per bench, hundreds of thousands of cycles away from the instruction that
# produced it. z486 ships the CPU's own contract tests, and the local patch is a
# CPU-behaviour change (the fourth change in docs/z486-local-patch.md), so a
# regression in it has to be reported by a test that names the instruction. That is
# this tier. It is Verilator-only, like the rest of the gate.
#
# The regression tests for the fourth, fifth and sixth changes are
# `seg_limit_dcache_miss`, `sreg_absent_gdt_load` and `gp_double_fault_deliver`,
# the seventh change's is `div_cyrix_probe`, and the eighth change's (upstream
# PR #2) is `spec_fetch_cpl_leak`. Their files are tracked in
# tests/z486/ instead of inside the submodule: the
# patch mechanism is `git diff`-shaped, and a new-file entry in it is dropped by
# the next regeneration (`git -C src/z486 diff`) -- measured when they were
# added. They are installed into the suite's programs/ before
# the run, which is where the suite's own runners look for a test (it scans
# programs/*.json).
#
# `sreg_absent_gdt_load` is the fifth change's regression test: a segment-register
# load whose GDT descriptor is absent (all zeros) with an all-zero IDT must escalate
# to the triple fault, not livelock.
#
# `gp_double_fault_deliver` is the sixth change's: an absent #GP gate (vector 13)
# with a USABLE #DF gate (vector 8) must deliver #DF through gate 8, the way a real
# 486 does, rather than escalating to a processor reset.
#
# `div_cyrix_probe` is the seventh change's (upstream PR #1): real Intel/AMD 486
# silicon perturbs SF/ZF/PF/AF as an undocumented side effect of unsigned DIV and
# Cyrix leaves them unchanged, so pre-CPUID detection software uses that to
# discriminate. It is carried verbatim from the PR and installed here.
#
# `spec_fetch_cpl_leak` is the eighth change's (upstream PR #2): z486's
# branch-target line buffer survived a front-end flush keyed only on its linear
# address, so a line buffered at CPL 0 could be re-owned by a ring-3 branch to
# the same address and execute supervisor-only code at ring 3. The test drives a
# ring-0 buffer fill, an outer-level IRET to ring 3, and a ring-3 branch to the
# buffered line: pre-fix ring 3 runs the trap and reports failure, post-fix the
# fetch faults with a user-protection #PF.
#
# `wb_order_same_dst` is NOT a local-patch test: it is the regression test for a
# REPORTED (and here refuted) upstream write-ordering bug -- two back-to-back
# memory-writing instructions naming the same register (`mov eax,[mem]` then
# `add eax,[mem]`, the Doom 1 1992-compiler pattern), which an outside developer
# suspected of landing in the same cycle with the OLDER write winning. It runs 27
# slots (both first-operand encodings, 8/16/32-bit, add/or/sub, base-register and
# ES-override EAs, cold-cache second operands, plus the different-destination and
# separated controls), twice (cold and warm), against a hand-computed table.
Keep it in this tier: it is the cheapest workload that
# reaches the deferred-load / registered-writeback interlock from a real program.
#
# Fails on any of: a test that fails (the runner exits non-zero), a run that does
# not end at 100%, or a run whose total is implausibly small -- so a runner that
# silently ran nothing (a missing .json, a stale binary) cannot pass.
#
# The bdca3b9 re-vendor's eight review-regression programs (`aaa_halfcarry`,
# `aas_halfborrow`, `bittst_after_wide_shift`, `ed_seg_limit_check`,
# `enter_check_cross_pf`, `neg_size_carry`, `rcl_count`, `shld_overflow`) are
# fork-tracked under src/z486/tests/programs/ and named below like the earlier
# fail-first programs: the count floor is the measured 89.
#
# The e5120a2 re-vendor (storeq forwarding replacing the store-patch queues) adds
# seven more programs - `partial_reg`, `flag_sequences`, `far_jump_pm`,
# `far_jump_real`, `smc_basic`, `smc_same_line`, `smc_store_patch_stress` - and
# fixes the AAA/AAS expected values; the count floor rises to the measured 96.
#
# The three real-mode PC-98 diagnostics (`seg_verdict_real`, `ed_stack_real`,
# `mcb_walk_real`) are tracked under tests/z486/ and installed below, so the
# floor is the measured 99 (2026-10 real-mode CPU-test round).
#
# The 4c8ebc3 re-vendor adds five more fork-tracked programs - `int_vec_telemetry`
# (the dbg_vec_fetch/dbg_vec_num regression), `seg_limit_edge`, `seg_stack_wrap_rm`
# (the ab145c7 segmented-memory boundary cases), `store_fwd_word`, `store_fwd_word_rm`
# (the 16-bit store->load forwarding program and its real-mode twin) - and the
# count floor rises to the measured 104.
#
# The 2026-10-04 re-vendor (paging grace, the expand-down B-bit, the shifter's
# deferred-flag capture, the fault-delivery CPL/branch-kind fixes) adds thirteen
# more fork-tracked programs - `cpl3_retry`/`cpl3_call_retry`/`cpl3_enter_retry`/
# `cpl3_push_retry`/`cpl3_pushw_retry` (entry CPL0 and the #GP/stack retries),
# `expand_down_b_bit`/`expand_down_stack` (the registered ED/D-B bits),
# `paging_grace` (the fault-pulse demand hold-off), `pf_store_held`/`pf_store_jcc`
# (restarting a faulting store with its own ESP), `shifter_stack_flags` (the
# deferred shift-flag result), `unreal_cs_cpl` (the entry CPL0 without a CS
# rewrite) and `v86_user_page` (the V86 implicit-supervisor DPL) - and the count
# floor rises to the measured 147.
#
# The 2026-10-07 re-vendor onto the fork's curated series on upstream 4bfdde0 carries
# 288 programs, every one fork-tracked (this tier installs nothing), and drops
# `int_vec_telemetry`: its check read dbg_vec_fetch telemetry the CPU no longer has, so
# it passed vacuously (the fork's src/z486/docs/fork-rebase-policy.md records why). The count
# floor rises to the measured 288.
#
# The later 2026-10-07 re-vendor onto the fork's `27df73f` adds `spec_fetch_cpl_buffer`
# (a branch-target line buffered at CPL 0 must not run at CPL 3): 289.
#
# The 2026-10-11 re-vendor onto the fork's `0ebf0d0` adds the hazard-audit programs
# (`hz_*`, `smc_spec_demote_rm`) and `throttle_rep_stosd`: 309.
#
# Requires nasm: it is the suite's own declared assembler dependency (the runners
# assemble each program before simulating it), and a missing toolchain is a loud
# error here rather than a skip, because a tier that did not run must not read as a
# tier that passed.
set -euo pipefail
cd "$(dirname "$0")/../.."

SUITE=src/z486/tests
LOG=${Z486_SUITE_LOG:-/tmp/z486_protected_mode.log}
# A floor, not the exact count: the suite grows upstream, and demanding equality
# would turn an upstream test addition into a gate failure, while dropping to 1/1
# (one test still passing after the rest stopped being discovered) must fail.
MIN_TESTS=${Z486_SUITE_MIN:-309}

command -v nasm >/dev/null || {
  echo "nasm is not installed: z486's suite assembles its own test programs" >&2
  exit 1
}

# src/z486 is vendored with the local patch already applied, so there is nothing to apply.

# The six fail-first regressions below are now FORK-TRACKED directly under
# src/z486/tests/programs/ (the 2026-10-03 fork rebase tracks its own programs as
# source), so they are NOT installed here anymore: installing the stale tests/z486/
# copies over them would clobber the fork's newer tracked versions. The runner
# discovers the tracked files itself; the grep checks below still pin each one.


# Nothing is installed into the vendored tree any more (2026-10-07): the PC-98 programs
# this tier used to keep in tests/z486/ (the real-mode diagnostics, the Zet98-derived
# checks, the long-REP progress checks) are fork-tracked under src/z486/tests/programs/,
# so the vendored tree is a plain copy of the fork. The runner discovers them itself; the
# grep checks below still pin each one.

make -C "$SUITE" obj_dir/Vtb_protected_mode

# The runner's exit status carries the verdict, and `set -e` would end the script
# on it before the checks below can say which test failed, so collect it first.
set +e
( cd "$SUITE" && ./test_protected_mode.py ) 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e

# The runner colors its verdict lines; strip the escapes so the checks read text.
PLAIN=$LOG.plain
sed -e 's/\x1b\[[0-9;]*m//g' "$LOG" > "$PLAIN"

[ "$rc" -eq 0 ] || {
  echo "FAIL: z486's protected-mode suite exited $rc; the failing test is in $PLAIN" >&2
  exit 1
}

# The named regression test first: a summary of 100% that does not include it means
# the test file went missing, which is the failure mode this tier exists for.
grep -qE '^PASS +seg_limit_dcache_miss' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass seg_limit_dcache_miss" >&2
  exit 1
}
grep -qE '^PASS +sreg_absent_gdt_load' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass sreg_absent_gdt_load" >&2
  exit 1
}
grep -qE '^PASS +gp_double_fault_deliver' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass gp_double_fault_deliver" >&2
  exit 1
}
grep -qE '^PASS +div_cyrix_probe' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass div_cyrix_probe" >&2
  exit 1
}
grep -qE '^PASS +spec_fetch_cpl_leak' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass spec_fetch_cpl_leak" >&2
  exit 1
}
grep -qE '^PASS +wb_order_same_dst' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass wb_order_same_dst" >&2
  exit 1
}
# The real-mode PC-98 diagnostics installed above: a 100% summary without one of
# them means the install dropped it, this tier's missing-file failure mode.
grep -qE '^PASS +seg_verdict_real' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass seg_verdict_real" >&2
  exit 1
}
grep -qE '^PASS +ed_stack_real' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass ed_stack_real" >&2
  exit 1
}
grep -qE '^PASS +mcb_walk_real' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass mcb_walk_real" >&2
  exit 1
}
# The Zet98-cross-referenced CPU tests installed above: a 100% summary without
# one of them means the install dropped it, this tier's missing-file failure mode.
grep -qE '^PASS +div_edges' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass div_edges" >&2
  exit 1
}
grep -qE '^PASS +divtest_ref' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass divtest_ref" >&2
  exit 1
}
grep -qE '^PASS +cs_indirect_call' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass cs_indirect_call" >&2
  exit 1
}
grep -qE '^PASS +flags_restore' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass flags_restore" >&2
  exit 1
}
# The c244785 re-vendor's two fail-first seg programs are fork-tracked under
# src/z486/tests/programs/ (git add -f): a 100% summary without them means the
# re-vendor dropped them, which is this tier's missing-file failure mode again.
grep -qE '^PASS +seg_limit_older_commit' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass seg_limit_older_commit" >&2
  exit 1
}
grep -qE '^PASS +seg_limit_stall_d2' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass seg_limit_stall_d2" >&2
  exit 1
}
# The bdca3b9 re-vendor's eight review-regression programs are fork-tracked under
# src/z486/tests/programs/ (git add -f): a 100% summary without one of them means
# the re-vendor dropped it, which is this tier's missing-file failure mode again.
grep -qE '^PASS +aaa_halfcarry' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass aaa_halfcarry" >&2
  exit 1
}
grep -qE '^PASS +aas_halfborrow' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass aas_halfborrow" >&2
  exit 1
}
grep -qE '^PASS +bittst_after_wide_shift' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass bittst_after_wide_shift" >&2
  exit 1
}
grep -qE '^PASS +ed_seg_limit_check' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass ed_seg_limit_check" >&2
  exit 1
}
grep -qE '^PASS +enter_check_cross_pf' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass enter_check_cross_pf" >&2
  exit 1
}
grep -qE '^PASS +neg_size_carry' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass neg_size_carry" >&2
  exit 1
}
grep -qE '^PASS +rcl_count' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass rcl_count" >&2
  exit 1
}
grep -qE '^PASS +shld_overflow' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass shld_overflow" >&2
  exit 1
}
# The e5120a2 re-vendor's seven new programs are fork-tracked under
# src/z486/tests/programs/ (git add -f): a 100% summary without one of them means
# the re-vendor dropped it, which is this tier's missing-file failure mode again.
grep -qE '^PASS +partial_reg' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass partial_reg" >&2
  exit 1
}
grep -qE '^PASS +flag_sequences' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass flag_sequences" >&2
  exit 1
}
grep -qE '^PASS +far_jump_pm' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass far_jump_pm" >&2
  exit 1
}
grep -qE '^PASS +far_jump_real' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass far_jump_real" >&2
  exit 1
}
grep -qE '^PASS +smc_basic' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass smc_basic" >&2
  exit 1
}
grep -qE '^PASS +smc_same_line' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass smc_same_line" >&2
  exit 1
}
grep -qE '^PASS +smc_store_patch_stress' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass smc_store_patch_stress" >&2
  exit 1
}
# The 4c8ebc3 re-vendor's five new programs are fork-tracked under
# src/z486/tests/programs/ (git add -f): a 100% summary without one of them means
# the re-vendor dropped it, which is this tier's missing-file failure mode again.
grep -qE '^PASS +seg_limit_edge' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass seg_limit_edge" >&2
  exit 1
}
grep -qE '^PASS +seg_stack_wrap_rm' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass seg_stack_wrap_rm" >&2
  exit 1
}
grep -qE '^PASS +store_fwd_word ' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass store_fwd_word" >&2
  exit 1
}
grep -qE '^PASS +store_fwd_word_rm' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass store_fwd_word_rm" >&2
  exit 1
}
# The long-REP watchdog regressions: named, so a summary of 100% that no longer
# contains them (a lost install line, a deleted source) cannot read as a pass.
grep -qE '^PASS +rep_stosd_4k' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass rep_stosd_4k" >&2
  exit 1
}
grep -qE '^PASS +rep_stosd_16k' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass rep_stosd_16k" >&2
  exit 1
}
grep -qE '^PASS +rep_stosd_64k' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass rep_stosd_64k" >&2
  exit 1
}
# The 186a30c re-vendor's eight round-2 programs are fork-tracked under
# src/z486/tests/programs/ (git add -f): a 100% summary without one of them means
# the re-vendor dropped it, which is this tier's missing-file failure mode again.
grep -qE '^PASS +xadd_cmpxchg' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass xadd_cmpxchg" >&2
  exit 1
}
grep -qE '^PASS +min_cmp' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass min_cmp" >&2
  exit 1
}
grep -qE '^PASS +min_xadd' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass min_xadd" >&2
  exit 1
}
grep -qE '^PASS +jcc_then_fault' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass jcc_then_fault" >&2
  exit 1
}
grep -qE '^PASS +of_stack_vs_ds' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass of_stack_vs_ds" >&2
  exit 1
}
grep -qE '^PASS +pe_cpl0' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass pe_cpl0" >&2
  exit 1
}
grep -qE '^PASS +pe_cs_visible' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass pe_cs_visible" >&2
  exit 1
}
grep -qE '^PASS +shl1_overflow' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass shl1_overflow" >&2
  exit 1
}
# The 3cdb73c re-vendor's six round-3 programs are fork-tracked under
# src/z486/tests/programs/ (git add -f): a 100% summary without one of them means
# the re-vendor dropped it, which is this tier's missing-file failure mode again.
grep -qE '^PASS +merge_collision' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass merge_collision" >&2
  exit 1
}
grep -qE '^PASS +probe_arpl' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass probe_arpl" >&2
  exit 1
}
grep -qE '^PASS +probe_bcd' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass probe_bcd" >&2
  exit 1
}
grep -qE '^PASS +probe_bsf_bsr' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass probe_bsf_bsr" >&2
  exit 1
}
grep -qE '^PASS +probe_invd' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass probe_invd" >&2
  exit 1
}
grep -qE '^PASS +probe_xchg' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass probe_xchg" >&2
  exit 1
}
summary=$(sed -n 's/^Summary: \([0-9]*\)\/\([0-9]*\) tests passed (\(100\.0%\))$/\1 \2/p' "$PLAIN")
[ -n "$summary" ] || {
  echo "FAIL: the suite did not report 100.0% (see $PLAIN)" >&2
  exit 1
}
read -r passed total <<<"$summary"
[ "$total" -ge "$MIN_TESTS" ] || {
  echo "FAIL: the suite ran only $total test(s) (< $MIN_TESTS)" >&2
  exit 1
}

echo "Z486 PROTECTED-MODE SUITE: PASS ($passed/$total, incl. seg_limit_dcache_miss, sreg_absent_gdt_load, gp_double_fault_deliver, div_cyrix_probe, spec_fetch_cpl_leak, wb_order_same_dst, seg_limit_older_commit, seg_limit_stall_d2, aaa_halfcarry, aas_halfborrow, bittst_after_wide_shift, ed_seg_limit_check, enter_check_cross_pf, neg_size_carry, rcl_count, shld_overflow, partial_reg, flag_sequences, far_jump_pm, far_jump_real, smc_basic, smc_same_line, smc_store_patch_stress, seg_verdict_real, ed_stack_real, mcb_walk_real, seg_limit_edge, seg_stack_wrap_rm, store_fwd_word, store_fwd_word_rm, div_edges, divtest_ref, cs_indirect_call, flags_restore, rep_stosd_4k, rep_stosd_16k, rep_stosd_64k, xadd_cmpxchg, min_cmp, min_xadd, jcc_then_fault, of_stack_vs_ds, pe_cpl0, pe_cs_visible, shl1_overflow, merge_collision, probe_arpl, probe_bcd, probe_bsf_bsr, probe_invd, probe_xchg, cpl3_retry, cpl3_call_retry, cpl3_enter_retry, cpl3_push_retry, cpl3_pushw_retry, expand_down_b_bit, expand_down_stack, paging_grace, pf_store_held, pf_store_jcc, shifter_stack_flags, unreal_cs_cpl, v86_user_page)"
