# iir1, vendored

Upstream: <https://github.com/berndporr/iir1> — tag `1.10.0`, the same version
Homebrew was supplying. MIT; see `COPYING`.

## Why it is here

DOSBox Staging's mixer builds its channel filters and its noise gate on iir1
(`src/audio/mixer.h`, `src/audio/private/noise_gate.h`, both `<Iir.h>`).
Linking Homebrew's `libiir.1.dylib` put an absolute `/opt/homebrew/opt/...`
install name in Boxer's binary *and* raised the binary's effective floor to the
macOS that bottle was built for — 26.0, against Boxer's own minimum of 12.0.
Building from source at Boxer's deployment target is the only thing that yields
a real 12.0 binary. See FINDINGS.md, **D25**.

## What was taken

The whole library, which is small: `Iir.h`, and `iir/` — six `.cpp` files and
their headers. Everything is upstream's, unmodified; there is no generated
header and nothing Boxer adds, so moving to a newer iir1 is a re-copy.

Upstream's `demo/`, `test/`, `docs/` and its CMake packaging are not copied.

## Build settings

The six `.cpp` files are compiled by the `Boxer` and `Boxer Standalone` targets
at the project's `MACOSX_DEPLOYMENT_TARGET` (12.0), which is the entire point.
`Vendor/iir1` goes on the header search path so DOSBox's `<Iir.h>` resolves.
