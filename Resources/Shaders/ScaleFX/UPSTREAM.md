# ScaleFX source provenance

- Repository: https://github.com/libretro/slang-shaders
- Pinned commit: `4812a82f6c9a11cc8b5a7447040a98c9fc80c00e`
- Preset: `edge-smoothing/scalefx/scalefx.slangp`
- Shader sources: `edge-smoothing/scalefx/shaders/scalefx-pass0.slang` through `scalefx-pass4.slang`
- Shared source: `stock.slang`

Local modification: the preset's `../../stock.slang` reference is rewritten to
`stock.slang` so this Boxer shader directory is self-contained. Shader math is
unchanged.

The ScaleFX shader sources include their MIT license notice in each file.
