# FluidSynth static dependency bundle

This bundle targets the FluidSynth dependency used by DOSBox-Staging 0.82.2's Meson source tree.

- FluidSynth: **2.3.3**
- DOSBox-Staging tag: `v0.82.2`
- DOSBox-Staging commit: `f8c24f87d7fb0f41c2b7ef2a1aa97d16a52206be`
- FluidSynth source archive SHA-256: `321f7d3f72206b2522f30a1cb8ad1936fd4533ffc4d29dd335b1953c9fb371e6`
- Architectures: `arm64`, `x86_64`
- Deployment target used for all bundled static archives: macOS 12.0
- FluidSynth options: static library, single-precision floats, no FluidSynth threads, no OpenMP, no platform MIDI/audio drivers, no SDL2 driver, no tests.

The bundled dependency archives are static and universal:

- `lib/libfluidsynth.a`
- `lib/libgthread-2.0.a`
- `lib/libglib-2.0.a`
- `lib/libpcre2-8.a`
- `lib/libintl.a`

The non-FluidSynth dependencies were rebuilt from source for both architectures:

- GLib: **2.84.4**
- gettext/libintl: **0.26**
- PCRE2: **10.45**
- libffi: **3.4.8** was rebuilt as a GLib build dependency; GLib's required static archives are included above.

The final application still links the macOS system frameworks required by GLib and gettext (`Foundation`, `CoreFoundation`, `AppKit`, `Carbon`, and `CoreServices`) and `libiconv`.

**Deployment note:** every object inspected in the universal FluidSynth, GLib, GThread, PCRE2, and gettext archives carries a macOS 12.0 minimum. This removes the previous Homebrew deployment-target mismatch, but it is not a macOS 11 compatibility claim. A macOS 11 build would require rebuilding the complete dependency graph and application with an 11.0 deployment target, then checking API availability and testing on macOS 11.

DOSBox-Staging 0.82.2 pins the Meson fallback to FluidSynth 2.3.3 (`subprojects/fluidsynth.wrap`). Its release notes mention FluidSynth 2.3.5 specifically for official Windows builds; that is not the macOS Meson source dependency used here.
