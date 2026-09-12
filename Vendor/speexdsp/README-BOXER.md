# SpeexDSP, vendored

Upstream: <https://github.com/xiph/speexdsp> — tag `SpeexDSP-1.2.1`, the same
version Homebrew was supplying. BSD-3-Clause; see `COPYING`.

## Why it is here

DOSBox Staging's mixer resamples through SpeexDSP (`src/audio/mixer.cpp`,
`<speex/speex_resampler.h>`). Linking Homebrew's `libspeexdsp.1.dylib` put an
absolute `/opt/homebrew/opt/...` install name in Boxer's binary *and* raised the
binary's effective floor to whatever macOS that bottle was built for — 26.0, against
Boxer's own minimum of 12.0. Homebrew's static archive does not help: its objects
carry the same `minos`. Building from source at Boxer's deployment target is the
only thing that yields a real 12.0 binary. See FINDINGS.md, **D25**.

## What was taken

Only the resampler and the headers it needs — not the preprocessor, echo
canceller, jitter buffer or FFT, none of which DOSBox calls:

    libspeexdsp/resample.c          the one translation unit Boxer compiles
    libspeexdsp/arch.h              its private headers, verbatim
    libspeexdsp/os_support.h
    libspeexdsp/resample_sse.h
    libspeexdsp/resample_neon.h
    libspeexdsp/fixed_generic.h     (only reached under FIXED_POINT; kept so
    libspeexdsp/fixed_debug.h        arch.h is unmodified)
    include/speex/speex_resampler.h the public API mixer.cpp includes
    include/speex/speexdsp_types.h

Every file above is upstream's, unmodified.

## What Boxer adds

    config.h                              replaces the autotools-generated one
    include/speex/speexdsp_config_types.h generated from the upstream .in

`config.h` is the only judgement call; it is commented in place. Nothing else
here diverges from upstream, so moving to a newer SpeexDSP is a re-copy.

## Build settings

`resample.c` is compiled by the `Boxer` and `Boxer Standalone` targets at the
project's `MACOSX_DEPLOYMENT_TARGET` (12.0), which is the entire point. It needs
`Vendor/speexdsp`, `Vendor/speexdsp/include` and `Vendor/speexdsp/libspeexdsp`
on the header search path, and `HAVE_CONFIG_H` defined so `arch.h` and
`os_support.h` pick up the `config.h` above.
