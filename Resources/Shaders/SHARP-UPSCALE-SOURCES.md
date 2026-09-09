# Sharp upscaler source manifest

Imported from https://github.com/libretro/slang-shaders at pinned commit
`4812a82f6c9a11cc8b5a7447040a98c9fc80c00e` (2026-08-25).

## Imported presets

- `edge-smoothing/omniscale/omniscale.slangp`
- `edge-smoothing/cleanEdge/cleanEdge-scale.slangp`
- `edge-smoothing/nis/nis.slangp`
- `edge-smoothing/xbr/other presets/xbr-mlv4-multipass.slangp`
- `edge-smoothing/vectorscale/vectorscale.slangp`
- `edge-smoothing/nedi/nedi-hybrid-sharper.slangp`

Only transitively referenced shader files and includes are copied. Repository-level
paths were deterministically rewritten inside the corresponding self-contained
Boxer shader directory:

- cleanEdge's shared include now resolves as `shaders/cleanEdge.inc`.
- NEDI's cheap-sharpen dependency now resolves as `shaders/cheap-sharpen.slang`.

Shader math is unchanged.

## Licensing

- OmniScale and cleanEdge retain their complete MIT notices in the copied sources.
- NIS retains NVIDIA's MIT notice in the copied sources.
- xBR MLV4 Multipass and NEDI retain their MIT/LGPL notices in the copied sources;
  the xBR upstream `README.md` is also retained.
- VectorScale is copied verbatim from the pinned repository. Its selected upstream
  files do not provide a separate license file; review upstream provenance before
  redistributing outside the terms already applicable to Boxer.

## Refreshing

Check out the desired libretro/slang-shaders commit, compare each preset and every
recursive dependency, repeat only the path rewrites listed above, then compile and
render every local preset through Boxer's pinned OpenEmuShaders/Metal pipeline.
Update the pin only after revalidation.
