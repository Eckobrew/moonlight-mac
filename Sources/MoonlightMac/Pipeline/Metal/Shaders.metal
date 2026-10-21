#include <metal_stdlib>
using namespace metal;

struct VertexInput {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOutput {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOutput streamVertexShader(
    uint vertexID [[vertex_id]],
    constant float2* positions [[buffer(0)]],
    constant float2* texCoords [[buffer(1)]]
) {
    VertexOutput out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// Rec. 709 YCbCr to Linear RGB Matrix
constant float3x3 kColorConversion709 = float3x3(
    float3(1.164,  1.164,  1.164),
    float3(0.000, -0.213,  2.112),
    float3(1.793, -0.533,  0.000)
);

// Rec. 709 Limited Range Offset
constant float3 kColorOffset709 = float3(-(16.0 / 255.0), -(128.0 / 255.0), -(128.0 / 255.0));

fragment float4 streamFragmentShaderBT709(
    VertexOutput in [[stage_in]],
    texture2d<float, access::sample> textureY [[texture(0)]],
    texture2d<float, access::sample> textureUV [[texture(1)]],
    sampler textureSampler [[sampler(0)]]
) {
    float y = textureY.sample(textureSampler, in.texCoord).r;
    float2 uv = textureUV.sample(textureSampler, in.texCoord).rg;

    float3 yuv = float3(y, uv) + kColorOffset709;
    float3 rgb = kColorConversion709 * yuv;

    return float4(clamp(rgb, 0.0, 1.0), 1.0);
}

// Rec. 2020 YCbCr to Linear RGB Matrix for HDR10
constant float3x3 kColorConversion2020 = float3x3(
    float3(1.164384,  1.164384,  1.164384),
    float3(0.000000, -0.187326,  2.141770),
    float3(1.678674, -0.650424,  0.000000)
);

fragment float4 streamFragmentShaderBT2020(
    VertexOutput in [[stage_in]],
    texture2d<float, access::sample> textureY [[texture(0)]],
    texture2d<float, access::sample> textureUV [[texture(1)]],
    sampler textureSampler [[sampler(0)]]
) {
    float y = textureY.sample(textureSampler, in.texCoord).r;
    float2 uv = textureUV.sample(textureSampler, in.texCoord).rg;

    float3 yuv = float3(y, uv) + kColorOffset709;
    float3 rgb = kColorConversion2020 * yuv;

    return float4(clamp(rgb, 0.0, 1.0), 1.0);
}

// MARK: - HDR (EDR) shaders
//
// These render into an rgba16Float drawable with wantsExtendedDynamicRangeContent enabled.
// CoreAnimation expects extended *linear* display values, so the encoded (PQ) YCbCr values are
// converted to linear light before returning, and values above 1.0 are preserved so they drive
// the display's extended range instead of being clipped.

// Rec. 709 YCbCr -> BT.2020 non-linear RGB (primaries conversion), for SDR content on an EDR layer.
constant float3x3 kRec709ToRec2020 = float3x3(
    float3(0.6274, 0.0691, 0.0164),
    float3(0.3293, 0.9195, 0.0880),
    float3(0.0433, 0.0114, 0.8956)
);

// SMPTE ST 2084 (PQ) EOTF: encodes/decodes absolute luminance in the 0..1 signal range.
static inline float pqToLinear(float n) {
    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;
    float np = pow(max(n, 0.0), 1.0 / m2);
    float num = max(np - c1, 0.0);
    float den = c2 - c3 * np;
    return pow(num / max(den, 1e-5), 1.0 / m1);
}

// SDR reference white in PQ signal units (~100 nits of a 10000 nit range).
constant float kSDRReferenceWhitePQ = 0.508;

fragment float4 streamFragmentShaderBT2020EDR(
    VertexOutput in [[stage_in]],
    texture2d<float, access::sample> textureY [[texture(0)]],
    texture2d<float, access::sample> textureUV [[texture(1)]],
    sampler textureSampler [[sampler(0)]]
) {
    float y = textureY.sample(textureSampler, in.texCoord).r;
    float2 uv = textureUV.sample(textureSampler, in.texCoord).rg;

    float3 yuv = float3(y, uv) + kColorOffset709;
    // Still PQ-encoded at this point.
    float3 pq = clamp(kColorConversion2020 * yuv, 0.0, 1.0);

    // Decode PQ to linear light, then scale so SDR white maps to 1.0 (EDR headroom above that).
    float3 linearRgb = float3(pqToLinear(pq.r), pqToLinear(pq.g), pqToLinear(pq.b));
    linearRgb /= pqToLinear(kSDRReferenceWhitePQ);

    return float4(linearRgb, 1.0);
}

fragment float4 streamFragmentShaderBT709EDR(
    VertexOutput in [[stage_in]],
    texture2d<float, access::sample> textureY [[texture(0)]],
    texture2d<float, access::sample> textureUV [[texture(1)]],
    sampler textureSampler [[sampler(0)]]
) {
    float y = textureY.sample(textureSampler, in.texCoord).r;
    float2 uv = textureUV.sample(textureSampler, in.texCoord).rg;

    float3 yuv = float3(y, uv) + kColorOffset709;
    // SDR/BT.709 is gamma-encoded sRGB-ish; convert to BT.2020 primaries and linearize.
    float3 rgb = clamp(kColorConversion709 * yuv, 0.0, 1.0);
    rgb = kRec709ToRec2020 * rgb;

    // Approximate sRGB EOTF (the stream is typically BT.709 with sRGB transfer).
    float3 linearRgb = select(rgb / 12.92, pow((rgb + 0.055) / 1.055, 2.4), rgb > 0.04045);

    return float4(linearRgb, 1.0);
}
