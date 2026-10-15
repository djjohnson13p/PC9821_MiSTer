# 6. Tools and gates

72. **`audio_clip` bench: re-source the "model twin" rows.** **NEEDS RE-VERIFICATION.** Some of
    `tb_pc9821_audio_clip`'s expected rows were derived from a model of the RTL rather than from a
    reference. **Next:** re-derive them from ymfm or NP2kai (never from our RTL).

101. **`src/opna` has no vendor-diff gate, unlike `src/z486`.** **KNOWN GAP (tools).**
     `tools/check_z486_patch_diff.py` holds `src/z486` to `docs/z486-local-patch.md`'s map.
     `src/opna` (jt12/jt49/jt08 from PC88_MiSTer plus the marked local changes listed in
     `src/opna/LICENSE-SCOPE.md`) has no equivalent, so whether an edit stays inside a marked
     `LOCAL CHANGE` block is checked by eye. **Next:** the same contract - a ledger of the recorded
     changes and a diff against a pinned PC88_MiSTer checkout reporting exactly that list, with
     exit 2 = a loud SKIP when the checkout is absent, never a silent pass.
