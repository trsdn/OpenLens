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

static inline float3 composite_overlay(float3 rgb,
                                       float2 outputCoord,
                                       texture2d<float> overlayTexture,
                                       constant RenderUniforms &u)
{
    if (u.overlayOpacity <= 0.0 || u.overlayRect.z <= 0.0 || u.overlayRect.w <= 0.0) {
        return rgb;
    }
    float2 ov = (outputCoord - u.overlayRect.xy) / u.overlayRect.zw;
    if (ov.x < 0.0 || ov.x > 1.0 || ov.y < 0.0 || ov.y > 1.0) {
        return rgb;
    }
    constexpr sampler overlaySampler(filter::linear, mip_filter::linear, address::clamp_to_edge);
    // The texture is premultiplied, so this is a straight source-over blend.
    float4 texel = overlayTexture.sample(overlaySampler, ov) * u.overlayOpacity;
    return rgb * (1.0 - texel.a) + texel.rgb;
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
