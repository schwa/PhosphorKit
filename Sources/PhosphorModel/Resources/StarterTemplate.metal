/* phosphor:environment */
// An empty environment block means the default: one drawable-sized `image`
// texture, written by one pass called `image`. Declare textures, passes and
// uniforms here when you need more — see docs/Front-Matter-Reference.md.

uint2 gid [[thread_position_in_grid]];

kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 uv = float2(gid) / uniforms.resolution;
    uniforms.textures.image.write(float4(uv.x, uv.y, 0.5 + 0.5 * sin(uniforms.time), 1.0), gid);
}
