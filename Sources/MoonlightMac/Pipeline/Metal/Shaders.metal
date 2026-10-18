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
