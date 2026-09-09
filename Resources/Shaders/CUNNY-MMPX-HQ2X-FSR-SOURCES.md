# CuNNy, MMPX, HQ2x, and FSR source manifest

Imported from https://github.com/libretro/slang-shaders at pinned commit
`4812a82f6c9a11cc8b5a7447040a98c9fc80c00e` (2026-08-25).

## Imported presets

- `edge-smoothing/cunny/CuNNy-veryfast-nvl-2x-luma.slangp`
- `edge-smoothing/cunny/CuNNy-fast-nvl-2x-luma.slangp`
- `edge-smoothing/cunny/CuNNy-4x16-nvl-2x-rgb.slangp`
- `edge-smoothing/scalenx/mmpx-ADV.slangp`
- `edge-smoothing/hqx/hq2x.slangp`
- `edge-smoothing/fsr/fsr.slangp`
- `edge-smoothing/artcnn/artcnn-c4f16-2x-luma.slangp`

Only transitively referenced sources, includes, LUTs, and textures are copied.
Repository-level paths are deterministically rewritten inside each self-contained
Boxer shader directory. Shader math is unchanged.

CuNNy retains its upstream `LICENSE` (GPL-3.0-or-later) and `README.md` in each
CuNNy directory. ArtCNN retains its upstream MIT `LICENSE` and `README.md`.
MMPX source carries its MIT notice. HQ2x source carries its LGPL-2.1-or-later
notice. FSR headers carry AMD's MIT license notice.

## Investigated but not imported

- No `CuNNy Clear` preset exists at the pinned commit.
- `anti-aliasing/smaa.slangp` and `edge-smoothing/fsr/smaa+fsr.slangp` are blocked
  by the pinned glslang compiler's rejection of SMAA sampler arguments. Upstream
  `SMAA.hlsl` also requires lossless ISO-8859-1 to UTF-8 normalization before the
  pinned OpenEmuShaders source loader can read it.

## Refreshing

Check out the desired `libretro/slang-shaders` commit, compare each imported
preset and every recursively included file, repeat the path rewrites, then
compile and render each preset through Boxer's pinned OpenEmuShaders framework.
Update this commit hash only after all entries have been revalidated.
