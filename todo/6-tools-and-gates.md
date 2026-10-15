# 6. Tools and gates

72. **`audio_clip` bench: re-source the "model twin" rows.** **NEEDS RE-VERIFICATION.** Some of
    `tb_pc9821_audio_clip`'s expected rows were derived from a model of the RTL. **Done when:**
    they are re-derived from ymfm or NP2kai (never from our RTL).

101. **`src/opna` has no vendor-diff gate, unlike `src/z486`.** **WORK.** Whether an edit stays
     inside a marked `LOCAL CHANGE` block (`src/opna/LICENSE-SCOPE.md`) is checked by eye.
     **Done when:** a `tools/` check diffs `src/opna` against a pinned PC88_MiSTer checkout and
     reports exactly the recorded list, with exit 2 = a loud SKIP when the checkout is absent.
