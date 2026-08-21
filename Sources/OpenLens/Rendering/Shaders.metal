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
    float y = encode_luma((luma - u.lumaOffset) * u.lumaScale);

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
    float2 chroma = chromaTexture.sample(videoSampler, in.sourceCoord).rg;

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
    float3 rgb = sourceTexture.sample(videoSampler, in.sourceCoord).rgb;
    rgb = composite_overlay(rgb, in.outputCoord, overlayTexture, u);
    return encode_luma(rgb_to_luma(saturate(rgb)));
}

fragment float2 openlens_fragment_chroma_bgra(VertexOut in [[stage_in]],
                                              texture2d<float> sourceTexture [[texture(0)]],
                                              texture2d<float> overlayTexture [[texture(2)]],
                                              constant RenderUniforms &u [[buffer(0)]])
{
    constexpr sampler videoSampler(filter::linear, mip_filter::none, address::clamp_to_edge);
    float3 rgb = sourceTexture.sample(videoSampler, in.sourceCoord).rgb;
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
    float3 rgb = ycbcr_to_rgb(luma, chroma, u.lumaOffset, u.lumaScale);
    rgb = composite_overlay(rgb, in.outputCoord, overlayTexture, u);
    return float4(saturate(rgb), 1.0);
}

fragment float4 openlens_fragment_bgra(VertexOut in [[stage_in]],
                                       texture2d<float> sourceTexture [[texture(0)]],
                                       texture2d<float> overlayTexture [[texture(2)]],
                                       constant RenderUniforms &u [[buffer(0)]])
{
    constexpr sampler videoSampler(filter::linear, mip_filter::none, address::clamp_to_edge);
    float3 rgb = sourceTexture.sample(videoSampler, in.sourceCoord).rgb;
    rgb = composite_overlay(rgb, in.outputCoord, overlayTexture, u);
    return float4(saturate(rgb), 1.0);
}
