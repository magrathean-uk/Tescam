#include <metal_stdlib>
using namespace metal;

struct VertexOut {
  float4 position [[position]];
  float2 texCoord;
};

vertex VertexOut vertex_main(const device float4* vertices [[buffer(0)]],
                             uint vid [[vertex_id]]) {
  VertexOut out;
  float4 v = vertices[vid];
  out.position = float4(v.xy, 0.0, 1.0);
  out.texCoord = v.zw;
  return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler samp [[sampler(0)]]) {
  if (!tex.get_width()) { return float4(0.0, 0.0, 0.0, 1.0); }
  return tex.sample(samp, in.texCoord);
}
