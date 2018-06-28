
#include "UnityCG.cginc"
#include "UnityGBuffer.cginc"
#include "UnityStandardUtils.cginc"

#include "../Common/Cell.cginc"
#include "../Common/Edge.cginc"
#include "../Common/Face.cginc"

#if defined(SHADOWS_CUBE) && !defined(SHADOWS_CUBE_IN_DEPTH_TEX)
#define PASS_CUBE_SHADOWCASTER
#endif

half4 _Color, _Emission;
sampler2D _MainTex;
float4 _MainTex_ST;

half _Glossiness;
half _Metallic;

struct appdata
{
  float4 vertex : POSITION;
  float2 uv : TEXCOORD0;
  uint vid : SV_VertexID;
  UNITY_VERTEX_INPUT_INSTANCE_ID
};

struct v2f
{
  float4 position : SV_POSITION;
#if defined(PASS_CUBE_SHADOWCASTER)
  // Cube map shadow caster pass
  float3 shadow : TEXCOORD0;
#elif defined(UNITY_PASS_SHADOWCASTER)
  // Default shadow caster pass
#else
  // GBuffer construction pass
  float3 normal : NORMAL;
  half3 ambient : TEXCOORD0;
  float3 wpos : TEXCOORD1;
#endif
  UNITY_VERTEX_INPUT_INSTANCE_ID
};

StructuredBuffer<Cell> _Cells;
StructuredBuffer<Edge> _Edges;
StructuredBuffer<Face> _Faces;

float4x4 _World2Local, _Local2World;
float _Debug;

void setup() {
  unity_ObjectToWorld = _Local2World;
  unity_WorldToObject = _World2Local;
}

v2f vert (appdata IN, uint iid : SV_InstanceID)
{
  v2f OUT;
  UNITY_SETUP_INSTANCE_ID(IN);
  UNITY_TRANSFER_INSTANCE_ID(IN, OUT);

  Face f = _Faces[iid];
  Cell c0 = _Cells[f.c0];
  Cell c1 = _Cells[f.c1];
  Cell c2 = _Cells[f.c2];
  float3 position = lerp(c0.position, lerp(c1.position, c2.position, saturate(IN.vid - 1)), saturate(IN.vid));
  position *= lerp(f.alive, 1, _Debug);
  float4 vertex = float4(position, 1);
  float3 wpos = mul(unity_ObjectToWorld, vertex).xyz;

  float3 normal = lerp(c0.normal, lerp(c1.normal, c2.normal, saturate(IN.vid - 1)), saturate(IN.vid));
  float3 wnrm = UnityObjectToWorldNormal(normal);

#if defined(PASS_CUBE_SHADOWCASTER)
  // Cube map shadow caster pass: Transfer the shadow vector.
  OUT.position = UnityObjectToClipPos(float4(wpos.xyz, 1));
  OUT.shadow = wpos.xyz - _LightPositionRange.xyz;
#elif defined(UNITY_PASS_SHADOWCASTER)
  // Default shadow caster pass: Apply the shadow bias.
  float scos = dot(wnrm, normalize(UnityWorldSpaceLightDir(wpos.xyz)));
  wpos.xyz -= wnrm * unity_LightShadowBias.z * sqrt(1 - scos * scos);
  OUT.position = UnityApplyLinearShadowBias(UnityWorldToClipPos(float4(wpos.xyz, 1)));
#else
  // GBuffer construction pass
  OUT.position = UnityWorldToClipPos(float4(wpos.xyz, 1));
  OUT.normal = wnrm;
  OUT.ambient = ShadeSHPerVertex(wnrm, 0);
  OUT.wpos = wpos.xyz;
#endif
  return OUT;
}

#if defined(PASS_CUBE_SHADOWCASTER)

// Cube map shadow caster pass
half4 frag(v2f IN) : SV_Target
{
  float depth = length(IN.shadow) + unity_LightShadowBias.x;
  return UnityEncodeCubeShadowDepth(depth * _LightPositionRange.w);
}

#elif defined(UNITY_PASS_SHADOWCASTER)

// Default shadow caster pass
half4 frag() : SV_Target 
{
  return 0; 
}

#else

// GBuffer construction pass
void frag(v2f IN, out half4 outGBuffer0 : SV_Target0, out half4 outGBuffer1 : SV_Target1, out half4 outGBuffer2 : SV_Target2, out half4 outEmission : SV_Target3) 
{
  half3 albedo = _Color.rgb;

  // PBS workflow conversion (metallic -> specular)
  half3 c_diff, c_spec;
  half refl10;
  c_diff = DiffuseAndSpecularFromMetallic(
    albedo, _Metallic, // input
    c_spec, refl10 // output
  );

  // Update the GBuffer.
  UnityStandardData data;
  data.diffuseColor = c_diff;
  data.occlusion = 1.0;
  data.specularColor = c_spec;
  data.smoothness = _Glossiness;
  data.normalWorld = normalize(IN.normal);
  UnityStandardDataToGbuffer(data, outGBuffer0, outGBuffer1, outGBuffer2);

  // Calculate ambient lighting and output to the emission buffer.
  half3 sh = ShadeSHPerPixel(data.normalWorld, IN.ambient, IN.wpos);
  outEmission = _Emission + half4(sh * c_diff, 1);
}

#endif
