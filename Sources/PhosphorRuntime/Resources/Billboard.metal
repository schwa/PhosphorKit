#include <metal_stdlib>
using namespace metal;

// Full-screen billboard used by PhosphorRenderer to blit the output texture
// to the drawable. Replaces MetalSprocketsAddOns' TextureBillboardPipeline.
//
// The vertex shader emits a full-screen triangle from the vertex id (no vertex
// buffer needed). `flipY` selects the texture-coordinate orientation so the
// runtime can match the previous TextureBillboardPipeline `flipY` behavior.

struct BillboardVaryings {
    float4 position [[position]];
    float2 texCoord;
};

struct BillboardUniforms {
    uint flipY;
};

vertex BillboardVaryings phosphor_billboard_vertex(
    uint vertexID [[vertex_id]],
    constant BillboardUniforms& uniforms [[buffer(0)]])
{
    // Full-screen triangle: clip-space positions and matching UVs.
    // vertexID 0 -> (-1,-1), 1 -> (3,-1), 2 -> (-1,3)
    float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    float2 p = positions[vertexID];

    BillboardVaryings out;
    out.position = float4(p, 0.0, 1.0);

    // Map clip space [-1,1] to texture space [0,1]. Metal textures have their
    // origin at the top-left, so V is flipped relative to clip-space Y by
    // default; `flipY` inverts that to match the configuration flag.
    float2 uv = p * 0.5 + 0.5;
    uv.y = 1.0 - uv.y;
    if (uniforms.flipY != 0) {
        uv.y = 1.0 - uv.y;
    }
    out.texCoord = uv;
    return out;
}

fragment float4 phosphor_billboard_fragment(
    BillboardVaryings in [[stage_in]],
    texture2d<float> source [[texture(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return source.sample(s, in.texCoord);
}
