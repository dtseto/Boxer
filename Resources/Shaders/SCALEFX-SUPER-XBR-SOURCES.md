# ScaleFX and Super-xBR source manifest

Imported from https://github.com/libretro/slang-shaders at pinned commit
`4812a82f6c9a11cc8b5a7447040a98c9fc80c00e` (2026-08-25).

## Upstream presets

- `edge-smoothing/scalefx/scalefx.slangp`
- `edge-smoothing/scalefx/scalefx-hybrid.slangp`
- `edge-smoothing/scalefx/scalefx+rAA.slangp`
- `edge-smoothing/scalefx/scalefx-9x.slangp`
- `edge-smoothing/xbr/super-xbr-fast.slangp`
- `edge-smoothing/xbr/super-xbr.slangp`
- `edge-smoothing/xbr/other presets/super-2xbr-3d-2p.slangp`
- `edge-smoothing/xbr/other presets/super-2xbr-3d-3p-smoother.slangp`
- `edge-smoothing/xbr/other presets/super-4xbr-3d-4p.slangp`
- `edge-smoothing/xbr/other presets/super-4xbr-3d-6p-smoother.slangp`
- `edge-smoothing/xbr/other presets/super-8xbr-3d-6p.slangp`

Only files transitively referenced by these presets are copied. Every shader
source retains its upstream copyright and MIT license notice.

## Local preset adaptations

- References to repository-level `stock.slang`, reverse-AA passes, and bicubic
  interpolation are rewritten to equivalent paths inside each self-contained
  Boxer shader directory.
- In ScaleFX +rAA, upstream's final-pass line `scale_type0 = viewport` is
  corrected to `scale_type8 = viewport`. The original index modifies the first
  pass and leaves the final bicubic pass without its intended viewport scale.

No shader math is modified.

## Refreshing

Check out the desired `libretro/slang-shaders` commit, compare each path above,
copy only its referenced pass files, repeat the deterministic path rewrites,
then compile every preset through Boxer's pinned OpenEmuShaders framework.
Update this commit hash only after all presets have been revalidated.
