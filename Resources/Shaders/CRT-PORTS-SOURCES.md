# Additional CRT shader sources

The CRT shader presets listed below were imported from libretro's
`slang-shaders` repository at commit
`4812a82f6c9a11cc8b5a7447040a98c9fc80c00e`.

Upstream repository: https://github.com/libretro/slang-shaders

| Boxer preset | Upstream preset | License |
| --- | --- | --- |
| CRT Guest Advanced Fast | `crt/crt-guest-advanced-fast.slangp` | GPL-2.0-or-later; see source headers and Boxer's root `LICENSE` |
| CRT Easymode | `crt/crt-easymode.slangp` | GPL; see source header and Boxer's root `LICENSE` |
| CRT Hyllian | `crt/crt-hyllian-fast.slangp` | MIT; full grant retained in the shader source |
| CRT Lottes | `crt/crt-lottes.slangp` | Public domain; declaration retained in the shader source |
| CRT Beans VGA | `crt/crt-beans-vga.slangp` | MIT; bundled `LICENSE`. The Blue Noise texture is CC0 as documented in the preset. |
| NewPixie CRT | `crt/newpixie-crt.slangp` | Dual MIT/public domain; full terms retained in each shader source |
| ZFast CRT | `crt/zfast-crt.slangp` | GPL-2.0-or-later; see source header and Boxer's root `LICENSE` |

The preset files were renamed for Boxer's shader menu and their relative paths
were preserved. No shader algorithms were modified. Boxer/OpenEmuShaders
forbids GLSL `#include` directives, so the CRT Beans VGA and ZFast sources have
their upstream include files expanded inline without functional changes.
