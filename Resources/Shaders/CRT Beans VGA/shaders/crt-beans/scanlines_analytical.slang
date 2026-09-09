#version 450

// SPDX-License-Identifier: MIT

layout(set = 0, binding = 0, std140) uniform UBO {
    mat4 MVP;
};

layout(push_constant) uniform Push {
    vec4 SourceSize;
    vec4 OutputSize;
    uint FrameCount;
    float MaxSpotSize;
    float MinSpotSize;
    float OddFieldFirst;
    float OverscanHorizontal;
    float OverscanVertical;
    float MaskType;
    float SubpixelMaskPattern;
    float SubpixelPattern;
    float DynamicMaskTriads;
} params;

#pragma format R16G16B16A16_SFLOAT

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
// BEGIN inlined parameters_analytical.inc
// SPDX-License-Identifier: MIT

#pragma parameter OddFieldFirst "Interlacing (0/1: bob/phase, 2: weave, 3: VGA, 4: off)" 0.0 0.0 4.0 1.0
// END inlined parameters_analytical.inc
// BEGIN inlined mask.inc
// SPDX-License-Identifier: MIT

#ifndef PI
#define PI 3.1415926535897932384626433832795
#endif

// This functions generates a static, subpixel-aware mask.
//
// Note this approach limits phosphor triad counts to integer divisors of the
// screen width in pixels.
//
// Parameters:
//     coord: The current uv coordinates on the screen
//     output_size: <x_size, y_size, 1 / x_size, 1 / y_size>
//         (equivalent to the Retroarch-provided OutputSize uniform)
//     subpixel_pattern: The subpixel arrangement of the monitor.
//         0.0: RGB
//         1.0: BGR
//     pixels_per_triad: The number of monitor pixels used to simulate one
//         phosphor triad. 2.0, 3.0, 4.0, and 5.0 are currently supported.
//         Anything else will result in a mask of all 1's (i.e. no mask).
//
// Returns:
//     A vec4 with the rgb components containing the rgb values to apply the
//     mask on the current pixel, and the a component containing the mask
//     coverage (the inverse of the proportion of active subpixels).
vec4 subpixel_aperture_grille(vec2 coord, vec4 output_size, float subpixel_pattern, float pixels_per_triad) {
    // We need the coordinate in viewport pixels.
    float x = coord.x * output_size.x;
    vec3 mask = vec3(1.0);
    float mask_coverage = 1.0;
    if (subpixel_pattern == 0.0) { // RGB subpixels
        if (pixels_per_triad == 2.0) { // <=1080p
            vec3[2] mask_tile = {
                    vec3(1.0, 0.0, 1.0),
                    vec3(0.0, 1.0, 0.0)
                };
            mask = mask_tile[int(mod(x, 2.0))];
            mask_coverage = 2.0;
        } else if (pixels_per_triad == 3.0) { // 1080p/1440p
            vec3[3] mask_tile = {
                    vec3(0.0, 0.0, 1.0),
                    vec3(0.0, 1.0, 0.0),
                    vec3(1.0, 0.0, 0.0)
                };
            mask = mask_tile[int(mod(x, 3.0))];
            mask_coverage = 3.0;
        } else if (pixels_per_triad == 4.0) { // 1440p/4k
            vec3[4] mask_tile = {
                    vec3(1.0, 0.0, 0.0),
                    vec3(1.0, 1.0, 0.0),
                    vec3(0.0, 1.0, 1.0),
                    vec3(0.0, 0.0, 1.0)
                };
            mask = mask_tile[int(mod(x, 4.0))];
            mask_coverage = 2.0;
        } else if (pixels_per_triad == 5.0) { // 4k, lower TVL
            vec3[5] mask_tile = {
                    vec3(1.0, 0.0, 0.0),
                    vec3(1.0, 0.0, 1.0),
                    vec3(0.0, 0.0, 1.0),
                    vec3(0.0, 1.0, 0.0),
                    vec3(0.0, 1.0, 0.0)
                };
            mask = mask_tile[int(mod(x, 5.0))];
            mask_coverage = 15.0 / 6.0;
        }
    } else { // BGR subpixels, same as above but red and blue values transposed
        if (pixels_per_triad == 2.0) { // <=1080p
            vec3[2] mask_tile = {
                    vec3(1.0, 0.0, 1.0),
                    vec3(0.0, 1.0, 0.0)
                };
            mask = mask_tile[int(mod(x, 2.0))];
            mask_coverage = 2.0;
        } else if (pixels_per_triad == 3.0) { // 1080p/1440p
            vec3[3] mask_tile = {
                    vec3(1.0, 0.0, 0.0),
                    vec3(0.0, 1.0, 0.0),
                    vec3(0.0, 0.0, 1.0)
                };
            mask = mask_tile[int(mod(x, 3.0))];
            mask_coverage = 3.0;
        } else if (pixels_per_triad == 4.0) { // 1440p/4k
            vec3[4] mask_tile = {
                    vec3(0.0, 0.0, 1.0),
                    vec3(0.0, 1.0, 1.0),
                    vec3(1.0, 1.0, 0.0),
                    vec3(1.0, 0.0, 0.0)
                };
            mask = mask_tile[int(mod(x, 4.0))];
            mask_coverage = 2.0;
        } else if (pixels_per_triad == 5.0) { // 4k, lower TVL
            vec3[5] mask_tile = {
                    vec3(0.0, 0.0, 1.0),
                    vec3(1.0, 0.0, 1.0),
                    vec3(1.0, 0.0, 0.0),
                    vec3(0.0, 1.0, 0.0),
                    vec3(0.0, 1.0, 0.0)
                };
            mask = mask_tile[int(mod(x, 5.0))];
            mask_coverage = 15.0 / 6.0;
        }
    }

    return vec4(mask, mask_coverage);
}

// This function generates an aperture grille mask for the current coordinates.
//
// It works by scaling and low pass filtering a simple RGB aperture grille and
// sampling at the output pixel center. The low pass kernel is a raised cosine:
//
//     (0.5 + 0.5 * cos(pi * x / radius)) / radius
//
// The output is the convolution of the mask and the low pass kernel, if the
// mask is considered to be a piecewise-constant function of R, G, and B.
// Equivalently, the mask could be considered to be a series of dirac delta
// functions and the result is the convolution of the mask, a box function (to
// give the mask width), and the low pass kernel.
//
// For a more in-depth description of a similar thing, see:
//
//     https://themaister.net/blog/2018/08/25/pseudo-bandlimited-pixel-art-filtering-in-3d-a-mathematical-derivation/
//
// Parameters:
//     coord: The current uv coordinates on the screen
//     output_size: <x_size, y_size, 1 / x_size, 1 / y_size>
//         (equivalent to the Retroarch-provided OutputSize uniform)
//     mask_triads: The number of phosphor triads to generate across the screen
//
// Returns:
//     A vec4 with the rgb components containing the rgb values to apply the
//     mask on the current pixel, and the a component containing the mask
//     coverage (the inverse of the integral of the mask). In this case, the
//     mask coverage is always 3.0.
vec4 dynamic_aperture_grille(vec2 coord, vec4 output_size, float mask_triads) {
    // Loops are unrolled and common terms collapsed for performance.
    const vec3[3] phosphors = {
        vec3(1.0, 0.0, 0.0),
        vec3(0.0, 1.0, 0.0),
        vec3(0.0, 0.0, 1.0)
    };
    // All units are in terms of phosphors (i.e. 1 == phosphor width).
    // Set the kernel radius to be one output pixel wide.
    float kernel_radius = 3.0 * mask_triads * output_size.z;
    float x = 3.0 * mask_triads * coord.x;
    vec3 mask = vec3(0.0);
    if (kernel_radius < 0.5) {
        float x1 = clamp((x - round(x)) / kernel_radius, -1.0, 1.0);
        // mod(x, 3.0) isn't exact in floating point, so we'll add a small
        // value. This might not make a noticeable difference.
        vec3 p0 = phosphors[int(mod(round(x) - 1.0, 3.0) + 1e-3)];
        vec3 p1 = p0.brg;
        mask = p0 + p1 + (p1 - p0) * (x1 + sin(PI * x1) / PI);
        mask *= 0.5;
    }
    else if (kernel_radius < 1.0) {
        float x1 = clamp((x - (floor(x) + 0.0)) / kernel_radius, -1.0, 1.0);
        float x2 = clamp((x - (floor(x) + 1.0)) / kernel_radius, -1.0, 1.0);
        vec3 p0 = phosphors[int(mod(floor(x) - 1.0, 3.0) + 1e-3)];
        vec3 p1 = p0.brg;
        vec3 p2 = p1.brg;
        mask = p0 + p2 +
                (p1 - p0) * (x1 + sin(PI * x1) / PI) +
                (p2 - p1) * (x2 + sin(PI * x2) / PI);
        mask *= 0.5;
    }
    else { // kernel_radius < 1.5
        // For a kernel radius >= 1.5, we should have even more terms, but the
        // mask starts to look bad before then anyway.
        float x1 = clamp((x - (round(x) - 1.0)) / kernel_radius, -1.0, 1.0);
        float x2 = clamp((x - (round(x) + 0.0)) / kernel_radius, -1.0, 1.0);
        float x3 = clamp((x - (round(x) + 1.0)) / kernel_radius, -1.0, 1.0);
        vec3 p0 = phosphors[int(mod(round(x) - 2.0, 3.0) + 1e-3)];
        vec3 p1 = p0.brg;
        vec3 p2 = p1.brg;
        vec3 p3 = p2.brg;
        mask = p0 + p3 +
                (p1 - p0) * (x1 + sin(PI * x1) / PI) +
                (p2 - p1) * (x2 + sin(PI * x2) / PI) +
                (p3 - p2) * (x3 + sin(PI * x3) / PI);
        mask *= 0.5;
    }

    return vec4(mask, 3.0);
}

// Blend the mask with the current pixel value and return the result.
//
// The blending is done by keeping the mask as strong as possible and fading it
// out only as necessary to maintain the overall brightness of the image.
//
// Mathematically, the blending is represented by:
//
//     f(v) = c * a * m(x) + b
//
// where:
//
//     * m(x) is the mask function (for example, a pulse wave with a duty
//       cycle of 1/3 for an aperture grille)
//     * c is the mask coverage (the inverse of the integral of m(x) over x
//       from 0 to 1)
//     * v is the pixel value
//
// We can solve for a and b in terms of c and v given the following
// constraints:
//
//     * 0 <= m(x) <= 1
//     * 0 <= f(v) <= 1
//     * The integral of f(v) over x from 0 to 1 = v
//
// (The third constraint is responsible for maintaining brightness.)
//
// Parameters:
//     mask: The mask to be applied to this pixel
//     pixel_value: The rgb value of this pixel (before masking)
//     mask_coverage: The inverse of the integral of the mask
//
// Returns:
//     A vec3 with the rgb value of this pixel after applying the mask.
vec3 blend_mask(vec3 mask, vec3 pixel_value, float mask_coverage) {
    vec3 a = clamp((pixel_value - 1) / (1 - mask_coverage), vec3(0.0), pixel_value);
    vec3 b = clamp((1 - mask_coverage * pixel_value) / (1 - mask_coverage), vec3(0.0), pixel_value);
    return mask_coverage * a * mask + b;
}
// END inlined mask.inc
// BEGIN inlined line_handling.inc
// SPDX-License-Identifier: MIT

struct lines_t {
    // Sample locations in [0,1] coordinate space, snapped to the middle of a
    // source texel.
    float upper_sample_y;
    float lower_sample_y;
    // Distance units are *scanlines heights*.
    float upper_distance_y;
    float lower_distance_y;
};

// Get the two closest lines to the given position.
lines_t get_closest_lines(float v, vec4 sourceSize) {
    float upper_sample_y = round(v * sourceSize.y) + 0.5;
    float lower_sample_y = upper_sample_y - 1.0;
    float upper_distance_y = upper_sample_y - v * sourceSize.y;
    float lower_distance_y = upper_distance_y - 1.0;

    // Transform *_sample_y into [0,1] coordinate space. We need them for the
    // texture sampling below.
    upper_sample_y *= sourceSize.w;
    lower_sample_y *= sourceSize.w;

    return lines_t(upper_sample_y, lower_sample_y, upper_distance_y, lower_distance_y);
}

// Get the two closest lines from the *even* field to the given position.
lines_t get_even_lines(float v, vec4 sourceSize) {
    float upper_sample_y = ceil(0.5 * v * sourceSize.y - 0.25) * 2.0 + 0.5;
    float lower_sample_y = upper_sample_y - 2.0;
    float upper_distance_y = 0.5 * (upper_sample_y - v * sourceSize.y);
    float lower_distance_y = upper_distance_y - 1.0;

    // Transform *_sample_y into [0,1] coordinate space. We need them for the
    // texture sampling below.
    upper_sample_y *= sourceSize.w;
    lower_sample_y *= sourceSize.w;

    return lines_t(upper_sample_y, lower_sample_y, upper_distance_y, lower_distance_y);
}

// Get the two closest lines from the *odd* field to the given position.
lines_t get_odd_lines(float v, vec4 sourceSize) {
    float upper_sample_y = ceil(0.5 * v * sourceSize.y + 0.25) * 2.0 - 0.5;
    float lower_sample_y = upper_sample_y - 2.0;
    float upper_distance_y = 0.5 * (upper_sample_y - v * sourceSize.y);
    float lower_distance_y = upper_distance_y - 1.0;

    // Transform *_sample_y into [0,1] coordinate space. We need them for the
    // texture sampling below.
    upper_sample_y *= sourceSize.w;
    lower_sample_y *= sourceSize.w;

    return lines_t(upper_sample_y, lower_sample_y, upper_distance_y, lower_distance_y);
}

// Get the two closest lines as if the source was line-doubled. Note that this
// means that the sample coordinates for the upper and lower lines may be the
// same, even though the distances are different.
lines_t get_doubled_lines(float v, vec4 sourceSize) {
    float upper_distance_y = ceil(2.0 * (v * sourceSize.y) - 0.5) + 0.5 - 2.0 * (v * sourceSize.y);
    float lower_distance_y = upper_distance_y - 1.0;
    float upper_sample_y = (ceil(v * sourceSize.y + 0.25) - 0.5) * sourceSize.w;
    float lower_sample_y = (ceil(v * sourceSize.y - 0.25) - 0.5) * sourceSize.w;

    return lines_t(upper_sample_y, lower_sample_y, upper_distance_y, lower_distance_y);
}
// END inlined line_handling.inc

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out float delta;
layout(location = 2) out vec2 viewportCoord;

void main() {
    gl_Position = MVP * Position;

    // Handle overscan.
    vTexCoord = (1.0 - vec2(params.OverscanHorizontal, params.OverscanVertical)) * (TexCoord - 0.5) + 0.5;

    // Distance units are *scanlines heights*. delta is the distance between
    // samples on the x-axis, and has to be adjusted by the aspect ratio.
    // Overscan changes the aspect ratio and needs to be taken into account.
    delta = params.OutputSize.x * params.OutputSize.w *
            params.SourceSize.y * params.SourceSize.z *
            (1 - params.OverscanVertical) / (1 - params.OverscanHorizontal);

    // Adjust delta if we're interlacing.
    if (params.OddFieldFirst <= 2.0 && params.SourceSize.y > 300.0) {
        // bob or weave
        delta = 0.5 * delta;
    } else if (params.OddFieldFirst == 3.0 && params.SourceSize.y < 350) {
        // VGA line doubling
        delta = 2.0 * delta;
    }

    // The viewport coordinates (*not* processed for overscan).
    // We need this for the mask.
    viewportCoord = TexCoord;
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in float delta;
layout(location = 2) in vec2 viewportCoord;
layout(location = 0) out vec4 FragColor;
layout(binding = 1) uniform sampler2D Source;
layout(binding = 2) uniform sampler2D Linearized;

#define PI 3.1415926535897932384626433832795

// Represents the convolution of the spot function over 1 texel. We can sum
// several calls of this function to solve the scanline convolution in a
// piecewise manner.
//
// The integral of:
//
//     MaxSpotSize * s *
//       (1 / w) * (2 * clamp(|y| / w, 0, 1)^3 - 3 * clamp(|y| / w, 0, 1)^2 + 1) *
//       (1 / w) * (1/2 + 1/2 * cos(pi * clamp((x - t) / w, -1, 1)))
//
// with respect to t over the interval [x0, x1], where:
//
//   * s is the sample value for this texel
//   * w is the radius of the spot for this texel (equivalently, the
//     full width at half maximum)
//   * x0 and x1 are the horizontal bounds of the texel along the scanline
//   * x is the current horizontal position along the scanline
//   * y is the current vertical position relative to the center of the scanline
//
// All units are in scanline widths (the vertical distance from the center of
// one scanline to the center of the next is 1).
//
// Note that a common factor of MaxSpotSize / (2 * pi) has been factored out of
// this function and should be multiplied back in externally.
vec3 spot_integral(vec3 sample_value, vec3 w_rcp, float x, float x0, float x1, float y) {
    vec3 edge0 = clamp(w_rcp * (x - x0), -1.0, 1.0);
    vec3 edge1 = clamp(w_rcp * (x - x1), -1.0, 1.0);
    vec3 y_ = clamp(abs(y) * w_rcp, 0.0, 1.0);
    return sample_value * w_rcp * ((y_ * y_) * (2.0 * y_ - 3.0) + 1.0) *
        (PI * edge0 + sin(PI * edge0) - PI * edge1 - sin(PI * edge1));
}

// sign(x) * 0.5 requires ~5 instructions because it needs to account for edge
// cases (0.0 and -0.0, etc) and multiply. This is 2 instructions.
vec3 fast_sign(vec3 val) {
    return vec3(val.r < 0.0 ? -0.5 : 0.5, val.g < 0.0 ? -0.5 : 0.5, val.b < 0.0 ? -0.5 : 0.5);
}

// This is basically the same as the above function, but using the cubic
// function as the horizontal component. This avoids the sin() calls, which may
// be slow on some GPUs. However, it uses more instructions in total.
vec3 spot_integral2(vec3 sample_value, vec3 w_rcp, float x, float x0, float x1, float y) {
    vec3 edge0 = clamp(w_rcp * (x - x0), -1.0, 1.0);
    vec3 edge1 = clamp(w_rcp * (x - x1), -1.0, 1.0);
    vec3 y_ = clamp(abs(y) * w_rcp, 0.0, 1.0);
    return sample_value * w_rcp * ((y_ * y_) * (2.0 * y_ - 3.0) + 1.0) *
        (((edge0 * edge0) * (fast_sign(edge0) * (edge0 * edge0) - edge0) + edge0) -
            ((edge1 * edge1) * (fast_sign(edge1) * (edge1 * edge1) - edge1) + edge1));
}

vec3 scanlines(lines_t lines, float u) {
    vec3 value = vec3(0.0);
    // TODO check bounds
    float start_x = params.SourceSize.z * (floor(u * params.SourceSize.x - (params.MaxSpotSize / delta)) + 0.5);
    float stop_x = params.SourceSize.z * (floor(u * params.SourceSize.x + (params.MaxSpotSize / delta)) + 1.0);
    float x = u * params.SourceSize.x * delta;
    for (float sample_x = start_x; sample_x < stop_x; sample_x += params.SourceSize.z) {
        vec3 upper_sample = textureLod(Linearized, vec2(sample_x, lines.upper_sample_y), 0.0).rgb;
        vec3 upper_width_rcp = textureLod(Source, vec2(sample_x, lines.upper_sample_y), 0.0).rgb;
        vec3 lower_sample = textureLod(Linearized, vec2(sample_x, lines.lower_sample_y), 0.0).rgb;
        vec3 lower_width_rcp = textureLod(Source, vec2(sample_x, lines.lower_sample_y), 0.0).rgb;
        float x0 = delta * (params.SourceSize.x * sample_x - 0.5);
        float x1 = x0 + delta;
        value += spot_integral(upper_sample, upper_width_rcp, x, x0, x1, lines.upper_distance_y);
        value += spot_integral(lower_sample, lower_width_rcp, x, x0, x1, lines.lower_distance_y);
    }
    // We pulled these common factors out of the integral. Multiply them now.
    return params.MaxSpotSize / (2 * PI) * value; // For spot_integral
    // return params.MaxSpotSize * value; // For spot_integral2
}

void main() {
    vec3 value = vec3(0.0);
    if (params.OddFieldFirst == 3.0 && params.SourceSize.y < 350) {
        // VGA line doubling
        lines_t lines = get_doubled_lines(vTexCoord.y, params.SourceSize);
        value = scanlines(lines, vTexCoord.x);
    } else if (params.OddFieldFirst == 4.0 || params.OddFieldFirst == 3.0 || params.SourceSize.y <= 300.0) {
        // no interlacing
        lines_t lines = get_closest_lines(vTexCoord.y, params.SourceSize);
        value = scanlines(lines, vTexCoord.x);
    } else if (params.OddFieldFirst == 2.0) {
        // weave
        // Simulate even and odd fields, then average them together
        lines_t lines_even = get_even_lines(vTexCoord.y, params.SourceSize);
        lines_t lines_odd = get_odd_lines(vTexCoord.y, params.SourceSize);
        value = 0.5 * (scanlines(lines_even, vTexCoord.x) + scanlines(lines_odd, vTexCoord.x));
    } else if ((params.FrameCount + (params.OddFieldFirst == 1.0 ? 1u : 0u)) % 2u == 0u) {
        // bob (odd phase)
        lines_t lines = get_odd_lines(vTexCoord.y, params.SourceSize);
        value = scanlines(lines, vTexCoord.x);
    } else {
        // bob (even phase)
        lines_t lines = get_even_lines(vTexCoord.y, params.SourceSize);
        value = scanlines(lines, vTexCoord.x);
    }

    if (params.MaskType == 1.0) {
        vec4 mask = subpixel_aperture_grille(viewportCoord, params.OutputSize, params.SubpixelPattern, params.SubpixelMaskPattern);
        value = blend_mask(mask.rgb, value, mask.a);
    } else if (params.MaskType == 2.0) {
        vec4 mask = dynamic_aperture_grille(viewportCoord, params.OutputSize, params.DynamicMaskTriads);
        value = blend_mask(mask.rgb, value, mask.a);
    } // Otherwise, no mask

    FragColor.rgb = value;
}
