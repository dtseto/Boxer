#version 450

/*
 * VGA fake double-scan prefilter.
 * Port of vga-1080p-fake-double-scan.glsl for OpenEmu's Slang/Metal path.
 */

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
    vec4 OutputSize;
    vec4 OriginalSize;
    vec4 SourceSize;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

const float SCANLINE_STRENGTH_MIN = 0.80;
const float SCANLINE_STRENGTH_MAX = 0.85;
const float COLOR_BOOST_EVEN = 4.80;
const float COLOR_BOOST_ODD = 1.40;
const float MASK_STRENGTH = 0.10;
const float GAMMA_INPUT = 2.40;
const float GAMMA_OUTPUT = 2.62;

vec3 maskWeights(vec2 coord)
{
    float on = 1.0;
    float off = 1.0 - MASK_STRENGTH;
    vec3 green = vec3(off, on, off);
    vec3 magenta = vec3(on, off, on);

    vec3 aperture = mix(magenta, green, floor(mod(coord.x, 2.0)));
    vec3 inverseAperture = mix(green, magenta, floor(mod(coord.x, 2.0)));

    // 2x2 shadow mask, equivalent to PHOSPHOR_LAYOUT 2.
    return mix(aperture, inverseAperture, floor(mod(coord.y, 2.0)));
}

vec4 gammaCorrectedBilinear(vec2 uv)
{
    vec2 texCoord = uv * global.SourceSize.xy - vec2(0.5);
    vec2 s0t0 = floor(texCoord) + vec2(0.5);
    vec2 s0t1 = s0t0 + vec2(0.0, 1.0);
    vec2 s1t0 = s0t0 + vec2(1.0, 0.0);
    vec2 s1t1 = s0t0 + vec2(1.0);

    vec2 inverseTextureSize = global.SourceSize.zw;
    vec4 cS0T0 = pow(texture(Source, s0t0 * inverseTextureSize), vec4(GAMMA_INPUT));
    vec4 cS0T1 = pow(texture(Source, s0t1 * inverseTextureSize), vec4(GAMMA_INPUT));
    vec4 cS1T0 = pow(texture(Source, s1t0 * inverseTextureSize), vec4(GAMMA_INPUT));
    vec4 cS1T1 = pow(texture(Source, s1t1 * inverseTextureSize), vec4(GAMMA_INPUT));

    vec2 weight = fract(texCoord);
    vec4 c0 = mix(cS0T0, cS1T0, weight.x);
    vec4 c1 = mix(cS0T1, cS1T1, weight.x);

    return mix(c0, c1, weight.y);
}

void main()
{
    vec2 halfPixel = vec2(0.5);
    vec2 sourceCoordinate = vTexCoord * global.OriginalSize.xy;
    vec2 texelFloored = floor(sourceCoordinate);
    vec2 fractional = fract(sourceCoordinate);
    vec2 prescale = ceil(global.OutputSize.xy / global.OriginalSize.xy);
    vec2 regionRange = halfPixel - halfPixel / prescale;
    vec2 centerDistance = fractional - halfPixel;
    vec2 f = (centerDistance - clamp(centerDistance, -regionRange, regionRange))
        * prescale + halfPixel;
    vec2 modTexel = min(texelFloored + f, global.OriginalSize.xy - halfPixel);

    vec4 color = gammaCorrectedBilinear(modTexel / global.SourceSize.xy);

    vec2 maskCoordinates = gl_FragCoord.xy;
    float luminance = dot(vec3(0.2126, 0.7152, 0.0722), color.rgb);
    float evenOdd = floor(mod(maskCoordinates.y, 2.0));
    float dimFactor = mix(
        1.0 - SCANLINE_STRENGTH_MAX,
        1.0 - SCANLINE_STRENGTH_MIN,
        luminance
    );
    float scanlineDim = clamp(evenOdd + dimFactor, 0.0, 1.0);

    color.rgb *= vec3(scanlineDim);
    color.rgb *= mix(vec3(COLOR_BOOST_EVEN), vec3(COLOR_BOOST_ODD), evenOdd);

    float saturation = mix(1.2, 1.03, evenOdd);
    float colorLength = length(color);
    color.r = pow(color.r + 1e-7, saturation);
    color.g = pow(color.g + 1e-7, saturation);
    color.b = pow(color.b + 1e-7, saturation);
    color = normalize(color) * colorLength;

    color.rgb *= maskWeights(maskCoordinates);
    color = pow(color, vec4(1.0 / GAMMA_OUTPUT));

    FragColor = clamp(color, 0.0, 1.0);
}
