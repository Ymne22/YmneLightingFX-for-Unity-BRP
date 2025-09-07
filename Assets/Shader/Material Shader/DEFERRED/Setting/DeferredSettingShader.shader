// Unity built-in shader source. Copyright (c) 2016 Unity Technologies. MIT license (see license.txt)

Shader "Hidden/DeferredSettingShader" {
Properties {
    _LightTexture0 ("", any) = "" {}
    _LightTextureB0 ("", 2D) = "" {}
    _ShadowMapTexture ("", any) = "" {}
    _SrcBlend ("", Float) = 1
    _DstBlend ("", Float) = 1
}
SubShader {

// Pass 1: Lighting pass
Pass {
    ZWrite Off
    Blend [_SrcBlend] [_DstBlend]

CGPROGRAM
#pragma target 3.0
#pragma vertex vert_deferred
#pragma fragment frag
#pragma multi_compile_lightpass
#pragma multi_compile ___ UNITY_HDR_ON

#pragma exclude_renderers nomrt

#include "UnityCG.cginc"
#include "UnityDeferredLibrary.cginc"
#include "UnityPBSLighting.cginc"
#include "UnityStandardUtils.cginc"
#include "UnityGBuffer.cginc"

// ---- START OF CUSTOM BRDF CODE ----

// These functions are used to calculate the BRDF terms for the deferred pass.
inline half D_GGX(half NdotH, half roughness) {
    half a = max(0.001, roughness * roughness);
    half a2 = a * a;
    half NdotH2 = NdotH * NdotH;
    half d = (NdotH2 * (a2 - 1.0) + 1.0);
    return a2 / (UNITY_PI * (1.0 + (a2 - 1.0) * NdotH2) * (1.0 + (a2 - 1.0) * NdotH2));
}

inline half G_SchlickGGX(half NdotV, half roughness) {
    half r = roughness + 1.0;
    half k = (r * r) / 2.0;
    return NdotV / (NdotV * (1.0 - k) + k);
}

inline half G_Smith(half NdotV, half NdotL, half roughness) {
    half ggx1 = G_SchlickGGX(NdotL, roughness);
    half ggx2 = G_SchlickGGX(NdotV, roughness);
    return ggx1 * ggx2;
}

inline half3 F_Schlick(half cosTheta, half3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

inline half Fd_Disney(half NdotV, half NdotL, half LdotH, half roughness) {
    half Fd90 = 0.5 + 2.0 * LdotH * LdotH * (roughness * roughness);
    half lightScatter = (1.0 + (Fd90 - 1.0) * pow(1.0 - NdotL, 5.0));
    half viewScatter = (1.0 + (Fd90 - 1.0) * pow(1.0 - NdotV, 5.0));
    return (lightScatter * 0.75) * viewScatter;
}

// --- THE MAIN BRDF OVERRIDE ---
// This function will be used in the deferred pass to calculate the lighting.
half4 Custom_BRDF1_Unity_PBS (half3 diffColor, half3 specColor, half occlusion, half smoothness,
    float3 normal, float3 viewDir,
    UnityLight light, UnityIndirect gi)
{
    half roughness = SmoothnessToRoughness(smoothness);

    // STYLISTIC ADJUSTMENT!
    // diffuse/matte look. remove multiply if want the original look.
    roughness = saturate(roughness * 2.0);

    float3 V = viewDir;
    float3 L = light.dir;
    float3 N = normal;
    float3 H = normalize(V + L);

    half NdotL = saturate(dot(N, L));
    half NdotV = abs(dot(N, V));
    half NdotH = saturate(dot(N, H));
    half LdotH = saturate(dot(L, H));
    
    // Specular Term using GGX
    half D = D_GGX(NdotH, roughness);
    half G = G_Smith(NdotV, NdotL, roughness);
    half3 F0 = lerp(half3(0.04, 0.04, 0.04), diffColor, specColor.r);
    half3 F = F_Schlick(LdotH, F0);
    half3 specular = (D * G * F) / (8.0 * NdotV * NdotL + 0.001);

    // STYLISTIC ADJUSTMENT!
    // Remove if want the original look.
    specular = min(specular, 4.0h);

    // Diffuse Term using Disney BRDF
    half3 kS = F;
    half oneMinusMetallic = 1.0 - specColor.r;
    half3 kD = (1.0 - kS) * oneMinusMetallic;
    half disneyDiffuse = Fd_Disney(NdotV, NdotL, LdotH, roughness);
    half3 diffuse = disneyDiffuse * kD * diffColor / UNITY_PI;
    
    // Final Assembly
    half3 directColor = (diffuse * occlusion + specular) * light.color * NdotL;
    half3 indirectDiffuse = gi.diffuse * diffColor * kD;
    half3 indirectSpecular = gi.specular * F_Schlick(NdotV, F0);
    
    half3 finalColor = directColor + indirectDiffuse + indirectSpecular;
    return half4(finalColor, 1);
}

#define UNITY_BRDF_PBS Custom_BRDF1_Unity_PBS

// ---- END OF CUSTOM BRDF CODE ----

sampler2D _CameraGBufferTexture0;
sampler2D _CameraGBufferTexture1;
sampler2D _CameraGBufferTexture2;

half4 CalculateLight (unity_v2f_deferred i)
{
    float3 wpos;
    float2 uv;
    float atten, fadeDist;
    UnityLight light;
    UNITY_INITIALIZE_OUTPUT(UnityLight, light);
    UnityDeferredCalculateLightParams (i, wpos, uv, light.dir, atten, fadeDist);

    light.color = _LightColor.rgb * atten;
    
    half4 gbuffer0 = tex2D (_CameraGBufferTexture0, uv);
    half4 gbuffer1 = tex2D (_CameraGBufferTexture1, uv);
    half4 gbuffer2 = tex2D (_CameraGBufferTexture2, uv);
    UnityStandardData data = UnityStandardDataFromGbuffer(gbuffer0, gbuffer1, gbuffer2);

    float3 eyeVec = normalize(wpos-_WorldSpaceCameraPos);

    UnityIndirect ind;
    UNITY_INITIALIZE_OUTPUT(UnityIndirect, ind);
    ind.diffuse = 0;
    ind.specular = 0;
    
    half4 res = UNITY_BRDF_PBS (data.diffuseColor, data.specularColor, data.occlusion, data.smoothness, data.normalWorld, -eyeVec, light, ind);

    return res;
}

#ifdef UNITY_HDR_ON
half4
#else
fixed4
#endif
frag (unity_v2f_deferred i) : SV_Target
{
    half4 c = CalculateLight(i);
    #ifdef UNITY_HDR_ON
    return c;
    #else
    return exp2(-c);
    #endif
}

ENDCG
}

// Pass 2: Final decode pass.
Pass {
    ZTest Always Cull Off ZWrite Off
    Stencil {
        ref [_StencilNonBackground]
        readmask [_StencilNonBackground]
        compback equal
        compfront equal
    }

CGPROGRAM
#pragma vertex vert
#pragma fragment frag
#pragma exclude_renderers nomrt
#include "UnityCG.cginc"

sampler2D _LightBuffer;
struct v2f {
    float4 vertex : SV_POSITION;
    float2 texcoord : TEXCOORD0;
};

v2f vert (float4 vertex : POSITION, float2 texcoord : TEXCOORD0)
{
    v2f o;
    o.vertex = UnityObjectToClipPos(vertex);
    o.texcoord = texcoord.xy;
#ifdef UNITY_SINGLE_PASS_STEREO
    o.texcoord = TransformStereoScreenSpaceTex(o.texcoord, 1.0f);
#endif
    return o;
}

fixed4 frag (v2f i) : SV_Target
{
    return -log2(tex2D(_LightBuffer, i.texcoord));
}
ENDCG
}

}
Fallback Off
}
