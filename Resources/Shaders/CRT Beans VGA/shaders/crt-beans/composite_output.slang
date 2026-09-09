#version 450

// SPDX-License-Identifier: MIT

layout(set = 0, binding = 0, std140) uniform UBO {
    mat4 MVP;
};

layout(push_constant) uniform Push {
    float OutputGamma;
    vec4 SourceSize;
    vec4 ScanlinesSize;
    uint FrameCount;
    float GlowSigma;
    float GlowAmount;
} params;

// BEGIN inlined parameters_common.inc
// SPDX-License-Identifier: MIT

#pragma parameter OutputGamma "Output gamma (0: sRGB, 1: 2.2 gamma)" 1.0 0.0 1.0 1.0
#pragma parameter OverscanHorizontal "Horizontal overscan (proportion to crop)" 0.0 0.0 0.1 0.01
#pragma parameter OverscanVertical "Vertical overscan (proportion to crop)" 0.0 0.0 0.1 0.01
#pragma parameter MaxSpotSize "Maximum spot size (proportion of scanline)" 0.90 0.6 1.0 0.05
#pragma parameter MinSpotSize "Minimum spot size (proportion of maximum)" 0.4 0.3 1.0 0.1
#pragma parameter MaskType "Mask type (0: disabled, 1: subpixel, 2: dynamic)" 2.0 0.0 2.0 1.0
#pragma parameter SubpixelPattern "Monitor subpixel pattern (0: RGB, 1: BGR)" 0.0 0.0 1.0 1.0
#pragma parameter SubpixelMaskPattern "Subpixel mask width (pixels per triad)" 4.0 2.0 5.0 1.0
#pragma parameter DynamicMaskTriads "Dynamic mask phosphor triads (per screen width)" 550.0 400.0 800.0 25.0
#pragma parameter GlowSigma "Glow width (proportion of screen height)" 0.05 0.01 0.10 0.01
#pragma parameter GlowAmount "Glow amount (mix ratio)" 0.04 0.0 0.10 0.005
// END inlined parameters_common.inc

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;

void main() {
    gl_Position = MVP * Position;
    vTexCoord = TexCoord;
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 FragColor;
layout(binding = 1) uniform sampler2D Source;
layout(binding = 2) uniform sampler2D Scanlines;
layout(binding = 3) uniform sampler2D BlueNoiseTex;

vec3 linear_to_srgb(vec3 rgb) {
    // Floating point inaccuracies could result in negative values, so we'll
    // clamp here to avoid NaNs.
    rgb = clamp(rgb, 0.0, 1.0);
    bvec3 cutoff = lessThan(rgb, vec3(0.0031308));
    vec3 lower = rgb * vec3(12.92);
    vec3 higher = vec3(1.055) * pow(rgb, vec3(1.0 / 2.4)) - vec3(0.055);

    return mix(higher, lower, cutoff);
}

vec3 srgb_to_linear(vec3 rgb) {
    // Floating point inaccuracies could result in negative values, so we'll
    // clamp here to avoid NaNs.
    rgb = clamp(rgb, 0.0, 1.0);
    bvec3 cutoff = lessThan(rgb, vec3(0.04045));
    vec3 lower = rgb / 12.92;
    vec3 higher = pow((rgb + 0.055) / 1.055, vec3(2.4));

    return mix(higher, lower, cutoff);
}

vec3 linear_to_gamma(vec3 rgb) {
    // Floating point inaccuracies could result in negative values, so we'll
    // clamp here to avoid NaNs.
    rgb = clamp(rgb, 0.0, 1.0);
    return pow(rgb, vec3(1.0 / 2.2));
}

vec3 gamma_to_linear(vec3 rgb) {
    // Floating point inaccuracies could result in negative values, so we'll
    // clamp here to avoid NaNs.
    rgb = clamp(rgb, 0.0, 1.0);
    return pow(rgb, vec3(2.2));
}

// Apply a simple 8-bit dither to minimize banding in the glow.
vec3 dither_srgb(vec3 rgb, ivec2 icoords) {
    // First get the noise value, with some random-looking offset each frame.
    // We know the texture is 64x64, so we can modulo with bit arithmetic.
    // Actual integer modulo is *very* slow on some GPUs.
    ivec2 offset = ivec2(params.FrameCount & 0x3f) * ivec2(17u, 13u);
    vec3 noise = texelFetch(BlueNoiseTex, (icoords + offset) & 0x3f, 0).rgb;

    const float quantum = 1.0 / 255.0;
    vec3 lower = floor(linear_to_srgb(rgb) / quantum) * quantum;
    vec3 upper = lower + quantum;
    vec3 threshold = mix(srgb_to_linear(lower), srgb_to_linear(upper), noise);
    return mix(lower, upper, lessThan(threshold, rgb));
}

// Apply a simple 8-bit dither to minimize banding in the glow.
vec3 dither_gamma(vec3 rgb, ivec2 icoords) {
    // First get the noise value, with some random-looking offset each frame.
    // We know the texture is 64x64, so we can modulo with bit arithmetic.
    // Actual integer modulo is *very* slow on some GPUs.
    ivec2 offset = ivec2(params.FrameCount & 0x3f) * ivec2(17u, 13u);
    vec3 noise = texelFetch(BlueNoiseTex, (icoords + offset) & 0x3f, 0).rgb;

    const float quantum = 1.0 / 255.0;
    vec3 lower = floor(linear_to_gamma(rgb) / quantum) * quantum;
    vec3 upper = lower + quantum;
    vec3 threshold = mix(gamma_to_linear(lower), gamma_to_linear(upper), noise);
    return mix(lower, upper, lessThan(threshold, rgb));
}

void main() {
    vec3 blur_value = textureLod(Source, vTexCoord, 0.0).rgb;
    ivec2 icoords = ivec2(floor(vTexCoord * params.ScanlinesSize.xy));
    vec3 scanlines_value = texelFetch(Scanlines, icoords, 0).rgb;
    vec3 out_value = mix(scanlines_value, blur_value, params.GlowAmount);
    if (params.OutputGamma < 0.5) {
        out_value = dither_srgb(out_value, icoords);
    } else {
        out_value = dither_gamma(out_value, icoords);
    }
    FragColor = vec4(out_value, 1.0);
}
