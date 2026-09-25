> [!NOTE]
> **About the `DosBox_Staging_0.83` branch**
>
> This branch is an experimental, unofficial fork of
> [MaddTheSane/Boxer](https://github.com/MaddTheSane/Boxer)'s `maddsV2` branch.
> It has two aims:
>
> - **Move Boxer's embedded emulator onto DOSBox Staging v0.83.0.** Boxer's
>   fork was based on DOSBox Staging 0.78.1 (last synced with upstream in
>   2021). The matching emulator changes are on the `boxer-0.83` branch of
>   [eduo/dosbox-staging](https://github.com/eduo/dosbox-staging), and the
>   `DOSBox-Staging` submodule is pinned to a commit on that branch. Where
>   upstream now provides extension points (`RenderBackend`, `MidiDevice`),
>   Boxer builds on them instead of patching DOSBox directly.
> - **Import eXoDOS collections.** Games packed as eXoDOS `.zip` archives can
>   be imported as Boxer gameboxes. The importer is written in Swift and
>   SwiftUI.
>
> The minimum macOS version rises from 10.14.4 to **13.0** (DOSBox Staging 0.83
> needs 12.0; the eXoDOS importer uses macOS 13 APIs). This is a work in
> progress and is not affiliated with or endorsed by the Boxer or DOSBox
> Staging maintainers. The rest of this README is the upstream `maddsV2` text,
> unchanged, so some of it (build requirements, supported macOS versions)
> doesn't apply to this branch.

## Building this branch

This replaces "Build requirements" below, which describes the original
project. It has been tested on **Apple Silicon (arm64) only**, with Xcode 26.6
and Xcode 27.0.

### Install first

- **macOS 13 or later**, and **Xcode 26 or later**.
- **Xcode's Metal toolchain.** Since Xcode 26 it is a separate download
  (about 700 MB), and every Xcode update removes it again:
  `xcodebuild -downloadComponent MetalToolchain`
- **[Homebrew](https://brew.sh)**, installed at `/opt/homebrew` (the Apple
  Silicon default). The project looks for asio's headers at that exact path.
- **asio** (headers only, not linked into the app) and **CMake** (builds
  OpenEmuShaders' SPIR-V and glslang tools): `brew install asio cmake`
- *Optional:* **SwiftLint**. The build only prints a warning without it.

The finished app is self-contained; it needs nothing from Homebrew at run
time.

### Steps

```bash
git clone --branch DosBox_Staging_0.83 https://github.com/eduo/Boxer.git
cd Boxer
git submodule update --init --recursive --force
```

The DOSBox Staging submodule comes from
[eduo/dosbox-staging](https://github.com/eduo/dosbox-staging/tree/boxer-0.83).
If any `Vendor/` folder ends up containing only `.git`, run the same
`git submodule update` command on that folder again. Always use the commits
the submodules are pinned to: OpenEmuShaders' latest commit is not
compatible with Boxer's shader code.

Build OpenEmuShaders' tools once, before the first Xcode build. They declare
a CMake version so old that CMake 4 refuses them, and a failed attempt leaves
a stale cache behind. Xcode then reports it as the misleading
``No rule to make target `SPIRV-Tools-opt'``.

```bash
printf '#!/bin/sh\nexec cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "$@"\n' > /tmp/cmake-compat
chmod +x /tmp/cmake-compat
cd Vendor/OpenEmuShaders/3rdparty
rm -rf SPIRV-Tools/build glslang/build
make CMAKE=/tmp/cmake-compat all
cd ../../..
```

Then build with the **`Boxer CI`** scheme. The plain `Boxer` scheme signs
with the original developer's Developer ID. The deployment-target override
is needed because the vendored submodules declare older macOS versions than
current Xcode accepts. Without it the build fails before any Boxer code
compiles:

```bash
xcodebuild -workspace Boxer.xcworkspace -scheme "Boxer CI" \
  -configuration Release -arch arm64 \
  MACOSX_DEPLOYMENT_TARGET=13.0 \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build
```

The app ends up in
`~/Library/Developer/Xcode/DerivedData/Boxer-*/Build/Products/Release/`.

---

![Boxer](http://boxerapp.com/static/images/gloves_96.png)

#### Some notes on building Boxer

The Boxer Xcode project is designed to be a painless one-click build. Here's a quick rundown of how it's set up:

#### Build requirements

To build the Boxer project you will need macOS 10.14 or higher and XCode 11.3 or higher.

All necessary frameworks and other dependencies are included in the Boxer repo, or as git submodules, so the project itself is all you'll need.

After cloning, run:

```bash
git submodule update --init --recursive
```

#### Build Targets

The Boxer project has three targets:

- "Boxer": the standard Boxer emulator you know and love, as seen on http://boxerapp.com. This is almost certainly the one you'll want to use.

- "Boxer Standalone": a cut-down version of Boxer that wraps up a gamebox into a single unified app. Game importing and settings UIs have been stripped out of this version, and it will only launch the gamebox that bundled inside it. This target is not meant to be used on its own: instead it's a build component for…

- "Boxer Bundler": a graphical tool for converting gameboxes into standalone apps using its own self-contained copy of Boxer Standalone.

#### Build Configurations

The Boxer target has 2 build configurations: Release and Debug. Both of them compile fully optimized 64-bit binaries using the LLVM compiler. Debug works almost exactly the same as Release but turns on console debug messages and additional error-checking.

#### App requirements

Boxer and Boxer Standalone both run on macOS 10.14.4 and above, while Boxer Bundler runs on OS X 10.8 and above.

OSX 10.5 and PowerPC support has been removed from the Boxer master branch: if you need these, use the older "leopard_legacy" maintenance branch from http://github.com/alunbestor/Boxer/tree/leopard_legacy/.

#### Having trouble?

If you have any problems building the Boxer project, or questions about Boxer's code, please get in touch with me at abestor@boxerapp.com and I'll help out as best I can.

#### License

The project is licensed using [GPLv2](./LICENSE). Originally developed
by Alun Bestor and other contributors.
