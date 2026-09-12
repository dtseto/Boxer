// Boxer's replacement for the config.h SpeexDSP's autotools build generates.
//
// Boxer compiles one translation unit of SpeexDSP -- libspeexdsp/resample.c,
// the mixer's resampler -- inside its own Xcode project and never runs
// SpeexDSP's configure, so the handful of defines that build actually needs are
// written out here instead. See Vendor/speexdsp/README-BOXER.md.
//
// The values match what `./configure` settles on for macOS: a floating-point
// build with the SIMD kernel for the host architecture. Those two probes are
// the only ones resample.c consults, so this stays short rather than being a
// transcription of the real config.h.

#ifndef BOXER_SPEEXDSP_CONFIG_H
#define BOXER_SPEEXDSP_CONFIG_H

// resample.c refuses to compile unless one of FIXED_POINT / FLOATING_POINT is
// set. macOS builds are floating point.
#define FLOATING_POINT

// Symbol visibility prefix. Boxer links resample.c straight into its binary
// rather than building a dylib, so nothing needs exporting.
#define EXPORT

// SIMD kernel. configure probes the compiler for these; the architecture
// macros say the same thing and survive a universal build, which a fixed value
// would not.
#if defined(__aarch64__) || defined(__arm64__)
#define USE_NEON
#elif defined(__x86_64__) || defined(__SSE2__)
#define USE_SSE
#define USE_SSE2
#endif

#endif // BOXER_SPEEXDSP_CONFIG_H
