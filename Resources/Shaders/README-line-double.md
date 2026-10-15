# Line Double shader presets

These presets add the VGA fake double-scan prefilter before the bundled CRT
shaders. The prefilter runs at the viewport size (scale_type = viewport,
scale = 1.0) and performs gamma-correct bilinear sampling, doubled scanlines,
colour boost/saturation, and a 2x2 phosphor mask.

In the bundled Boxer build, keep this directory structure under
Resources/Shaders/:

- Line Double/shaders/vga-fake-double-scan.slang
- CRT Easymode - Line Double/CRT Easymode - Line Double.slangp
- CRT Geom - Line Double/CRT Geom - Line Double.slangp
- CRT Lottes - Line Double/CRT Lottes - Line Double.slangp
- CRT Royale - Line Double/CRT Royale - Line Double.slangp
- CRT ZFast - Line Double/CRT ZFast - Line Double.slangp

Boxer derives the menu name from the containing directory, so the preset
directory names are intentional. For a user install, copy those four
directories to ~/Library/Application Support/Boxer/Shaders/; restart Boxer
or reload its custom shaders.

The Easymode preset sets SCANLINE_STRENGTH = 0.0. CRT Geom exposes a
minimum scanline_weight of 0.1, so that preset uses the minimum to reduce
its second scanline contribution. Lottes sets hardScan = 0.0 and
hardBloomScan = -1.0, its least-intrusive scanline settings. ZFast sets
LOWLUMSCAN = 0.0 and HILUMSCAN = 0.0 while retaining its finemask pass.
The checked-in Royale shader is the 13-pass Kurozumi variant; its complete
pipeline is retained and its beam sigma values are widened to 1.0 to
minimise additional scanline modulation. The original ZFast CRT menu title
is now CRT ZFast.
