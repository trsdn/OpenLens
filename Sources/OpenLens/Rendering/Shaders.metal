#include <metal_stdlib>
using namespace metal;

struct RenderUniforms {
    // Crop window in normalized source space (top-left origin).
    float4 cropRect;
    // Overlay placement in normalized output space.
    float4 overlayRect;
    float  overlayOpacity;
    // 1 when the source should be mirrored horizontally.
    float  mirror;
    // Luma offset/scale for video-range vs full-range YCbCr.
    float  lumaOffset;
    float  lumaScale;
    // Colour correction. Neutral is 1, 0, 1, 1, 1, 0, 0, 0, 0, 0 — see
    // ImageAdjustments.swift, which precomputes these so the shader never
    // recomputes a value that only changes when a slider moves.
    float  exposureGain;
    float  blackLevel;
    float  levelsGain;
    float  midtoneExponent;
    float  contrastAmount;
    float  saturationGain;
    float  temperatureShift;
    float  tintShift;
    float  shadowShift;
    float  highlightShift;
};

struct VertexOut {
    float4 position [[position]];
    // Coordinates into the source texture, already cropped.
    float2 sourceCoord;
    // Coordinates in output space, 0...1, used to place the overlay.
    float2 outputCoord;
};

// A single oversized triangle covers the viewport with no index buffer and no
// vertex buffer — cheaper to submit than a quad and avoids the diagonal seam.
vertex VertexOut openlens_vertex(uint vertexID [[vertex_id]],
                                 constant RenderUniforms &u [[buffer(0)]])
{
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    const float2 coords[3]    = { float2(0.0, 1.0),   float2(2.0, 1.0),  float2(0.0, -1.0) };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    float2 uv = coords[vertexID];
    out.outputCoord = uv;

    float2 cropUV = uv;
    if (u.mirror > 0.5) {
        cropUV.x = 1.0 - cropUV.x;
    }
    // The crop is applied here, in the vertex stage: zooming costs nothing at
    // runtime because it is only a remap of texture coordinates.
    out.sourceCoord = u.cropRect.xy + cropUV * u.cropRect.zw;
    return out;
}

static inline float3 ycbcr_to_rgb(float luma, float2 chroma, float offset, float scale)
{
    float y = (luma - offset) * scale;
    float cb = chroma.x - 0.5;
    float cr = chroma.y - 0.5;
    return float3(y + 1.402 * cr,
                  y - 0.344136 * cb - 0.714136 * cr,
                  y + 1.772 * cb);
}

static inline float4 overlay_texel(float2 outputCoord,
                                   texture2d<float> overlayTexture,
                                   constant RenderUniforms &u)
{
    if (u.overlayOpacity <= 0.0 || u.overlayRect.z <= 0.0 || u.overlayRect.w <= 0.0) {
        return float4(0.0);
    }
    float2 ov = (outputCoord - u.overlayRect.xy) / u.overlayRect.zw;
    if (ov.x < 0.0 || ov.x > 1.0 || ov.y < 0.0 || ov.y > 1.0) {
        return float4(0.0);
    }
    constexpr sampler overlaySampler(filter::linear, mip_filter::linear, address::clamp_to_edge);
    return overlayTexture.sample(overlaySampler, ov) * u.overlayOpacity;
}

static inline float3 composite_overlay(float3 rgb,
                                       float2 outputCoord,
                                       texture2d<float> overlayTexture,
                                       constant RenderUniforms &u)
{
    float4 texel = overlay_texel(outputCoord, overlayTexture, u);
    // The texture is premultiplied, so this is a straight source-over blend.
    return rgb * (1.0 - texel.a) + texel.rgb;
}

// MARK: - NV12 output
//
// The virtual camera vends 420v, so the render targets are the two planes of an
// NV12 buffer rather than a single BGRA one. That is 3.11 MB per frame instead
// of 8.29 MB — every byte of which CoreMediaIO copies into the sink queue and
// the conferencing app then feeds to its H.264 encoder, which wants YCbCr
// anyway.
//
// For a biplanar camera (which is what every source here negotiates) this also
// deletes the YpCbCr -> RGB -> YpCbCr round trip: the shader now only crops, in
// the colour space the pixels already arrived in.

constant float kVideoLumaOffset = 16.0 / 255.0;
constant float kVideoLumaScale  = 255.0 / 219.0;

// Exact inverse of ycbcr_to_rgb's luma term, so a video-range source survives
// the pass untouched.
static inline float encode_luma(float y)
{
    return y / kVideoLumaScale + kVideoLumaOffset;
}

static inline float rgb_to_luma(float3 rgb)
{
    return dot(rgb, float3(0.299, 0.587, 0.114));
}

static inline float2 rgb_to_chroma(float3 rgb)
{
    float y = rgb_to_luma(rgb);
    return float2((rgb.b - y) / 1.772, (rgb.r - y) / 1.402) + 0.5;
}

// MARK: - Colour correction
//
// Split along the same seam as the NV12 planes: exposure, levels and contrast
// are tonal and belong to luma, white balance and saturation are colour and
// belong to chroma. Each shader therefore only pays for the half it already
// samples — with one deliberate exception, the shadow and highlight tints,
// which need the pixel's brightness to know how far to shift it.
//
// Applied to the camera image *before* the overlay is composited, so a logo
// keeps the colours it was authored in no matter how the picture is graded.

/// `y` is full-range luma in 0...1, and the result is clamped so an
/// overexposed pixel lands on legal white instead of overshooting into the
/// superwhite range that video-range consumers do not expect.
///
/// Order matters and follows a darkroom rather than the struct layout:
/// exposure sets how much light there is, the levels then decide which part of
/// that becomes black and white, and contrast reshapes what is left in
/// between. Running contrast first would only stretch tones that the levels
/// are about to crop away.
static inline float adjust_luma(float y, constant RenderUniforms &u)
{
    y *= u.exposureGain;
    y = saturate((y - u.blackLevel) * u.levelsGain);
    // pow() genuinely varies per pixel here, unlike the coefficients above,
    // so it cannot be hoisted out of the shader.
    y = pow(y, u.midtoneExponent);
    // An S rather than a straight slope: the (1 - |2y - 1|) term falls to zero
    // at both ends, so no amount of contrast can push a highlight into
    // clipping or crush a shadow that the black point had left visible.
    y += u.contrastAmount * (y - 0.5) * (1.0 - abs(2.0 * y - 1.0));
    return saturate(y);
}

/// `y` is the *graded* luma, so the tint zones follow the picture the viewer
/// ends up seeing rather than the one the camera sent.
///
/// Temperature is applied after saturation rather than before, so that pulling
/// saturation to zero and then warming the image gives a tinted monochrome
/// picture instead of a grey one.
static inline float2 adjust_chroma(float2 chroma, float y, constant RenderUniforms &u)
{
    float2 centred = (chroma - 0.5) * u.saturationGain;
    // Wide, overlapping ramps rather than hard bands: a face crosses both of
    // them, and any edge sharp enough to see would show up as a coloured
    // contour along the cheekbone.
    float shadow = saturate(1.0 - y * 2.2);
    float highlight = saturate((y - 0.55) / 0.45);
    // The two global white balance controls scale with brightness. A real white
    // balance is a per-channel gain applied in linear light, so its effect on a
    // pixel is proportional to how much light that pixel carries: black has no
    // colour cast to correct and stays black. A flat chroma offset instead hits
    // a near-black pixel just as hard in absolute terms, which is proportionally
    // enormous — enough to drain a black shirt of its blue and swing a neutral
    // dark background green long before the correction reaches a lit face.
    float balance = u.temperatureShift * y;
    float tint = u.tintShift * y;
    // The split-tone controls stay flat, because tinting the darkest part of the
    // picture is precisely what they are for; scaling those by luma would cancel
    // the shadow control out against its own weighting curve.
    float shift = balance + u.shadowShift * shadow + u.highlightShift * highlight;
    // Warm means more red and less blue, which in YCbCr is Cr up and Cb down.
    centred.x -= shift;
    centred.y += shift;
    // Tint is the other axis: magenta lifts red and blue together and pushes
    // green down, so both components move the same way.
    centred.x += tint;
    centred.y += tint;
    return saturate(centred + 0.5);
}

/// The RGB equivalent, for sources that do not arrive as YCbCr.
///
/// Routing through luma/chroma rather than grading in RGB directly is what
/// keeps a BGRA camera looking identical to a YCbCr one at the same settings.
static inline float3 adjust_rgb(float3 rgb, constant RenderUniforms &u)
{
    float y = adjust_luma(rgb_to_luma(rgb), u);
    float2 chroma = adjust_chroma(rgb_to_chroma(rgb), y, u);
    return ycbcr_to_rgb(y, chroma, 0.0, 1.0);
}

// Alpha blending commutes with the YCbCr transform: because YCbCr = M*RGB + o
// is affine, M(aA + (1-a)B) + o == a(MA + o) + (1-a)(MB + o). Compositing the
// overlay per plane is therefore exactly equivalent to compositing it in RGB
// and converting afterwards — no approximation.
fragment float openlens_fragment_luma_biplanar(VertexOut in [[stage_in]],
                                               texture2d<float> lumaTexture [[texture(0)]],
                                               texture2d<float> chromaTexture [[texture(1)]],
                                               texture2d<float> overlayTexture [[texture(2)]],
                                               constant RenderUniforms &u [[buffer(0)]])
{
    constexpr sampler videoSampler(filter::linear, mip_filter::none, address::clamp_to_edge);
    float luma = lumaTexture.sample(videoSampler, in.sourceCoord).r;
    float y = encode_luma(adjust_luma((luma - u.lumaOffset) * u.lumaScale, u));

    float4 texel = overlay_texel(in.outputCoord, overlayTexture, u);
    if (texel.a <= 0.0) { return y; }
    return y * (1.0 - texel.a) + encode_luma(rgb_to_luma(texel.rgb));
}

fragment float2 openlens_fragment_chroma_biplanar(VertexOut in [[stage_in]],
                                                  texture2d<float> lumaTexture [[texture(0)]],
                                                  texture2d<float> chromaTexture [[texture(1)]],
                                                  texture2d<float> overlayTexture [[texture(2)]],
                                                  constant RenderUniforms &u [[buffer(0)]])
{
    constexpr sampler videoSampler(filter::linear, mip_filter::none, address::clamp_to_edge);
    // The tint zones are keyed off brightness, so the chroma pass has to know
    // the luma at this pixel. Chroma is quarter resolution, which is why this
    // second read is affordable.
    float luma = lumaTexture.sample(videoSampler, in.sourceCoord).r;
    float y = adjust_luma((luma - u.lumaOffset) * u.lumaScale, u);
    float2 chroma = adjust_chroma(chromaTexture.sample(videoSampler, in.sourceCoord).rg, y, u);

    float4 texel = overlay_texel(in.outputCoord, overlayTexture, u);
    if (texel.a <= 0.0) { return chroma; }
    // Premultiplied RGB has to be un-premultiplied before the chroma difference
    // is meaningful; the alpha weight is reapplied by the blend below.
    float3 straight = texel.rgb / max(texel.a, 1e-4);
    return chroma * (1.0 - texel.a) + rgb_to_chroma(straight) * texel.a;
}

fragment float openlens_fragment_luma_bgra(VertexOut in [[stage_in]],
                                           texture2d<float> sourceTexture [[texture(0)]],
                                           texture2d<float> overlayTexture [[texture(2)]],
                                           constant RenderUniforms &u [[buffer(0)]])
{
    constexpr sampler videoSampler(filter::linear, mip_filter::none, address::clamp_to_edge);
    float3 rgb = adjust_rgb(sourceTexture.sample(videoSampler, in.sourceCoord).rgb, u);
    rgb = composite_overlay(rgb, in.outputCoord, overlayTexture, u);
    return encode_luma(rgb_to_luma(saturate(rgb)));
}

fragment float2 openlens_fragment_chroma_bgra(VertexOut in [[stage_in]],
                                              texture2d<float> sourceTexture [[texture(0)]],
                                              texture2d<float> overlayTexture [[texture(2)]],
                                              constant RenderUniforms &u [[buffer(0)]])
{
    constexpr sampler videoSampler(filter::linear, mip_filter::none, address::clamp_to_edge);
    float3 rgb = adjust_rgb(sourceTexture.sample(videoSampler, in.sourceCoord).rgb, u);
    rgb = composite_overlay(rgb, in.outputCoord, overlayTexture, u);
    return rgb_to_chroma(saturate(rgb));
}

fragment float4 openlens_fragment_biplanar(VertexOut in [[stage_in]],
                                           texture2d<float> lumaTexture [[texture(0)]],
                                           texture2d<float> chromaTexture [[texture(1)]],
                                           texture2d<float> overlayTexture [[texture(2)]],
                                           constant RenderUniforms &u [[buffer(0)]])
{
    constexpr sampler videoSampler(filter::linear, mip_filter::none, address::clamp_to_edge);
    float luma = lumaTexture.sample(videoSampler, in.sourceCoord).r;
    float2 chroma = chromaTexture.sample(videoSampler, in.sourceCoord).rg;
    // Graded in YCbCr and only then converted, exactly as the NV12 path does,
    // so the preview is a faithful match for what the call actually receives.
    float y = adjust_luma((luma - u.lumaOffset) * u.lumaScale, u);
    float3 rgb = ycbcr_to_rgb(y, adjust_chroma(chroma, y, u), 0.0, 1.0);
    rgb = composite_overlay(rgb, in.outputCoord, overlayTexture, u);
    return float4(saturate(rgb), 1.0);
}

fragment float4 openlens_fragment_bgra(VertexOut in [[stage_in]],
                                       texture2d<float> sourceTexture [[texture(0)]],
                                       texture2d<float> overlayTexture [[texture(2)]],
                                       constant RenderUniforms &u [[buffer(0)]])
{
    constexpr sampler videoSampler(filter::linear, mip_filter::none, address::clamp_to_edge);
    float3 rgb = adjust_rgb(sourceTexture.sample(videoSampler, in.sourceCoord).rgb, u);
    rgb = composite_overlay(rgb, in.outputCoord, overlayTexture, u);
    return float4(saturate(rgb), 1.0);
}
