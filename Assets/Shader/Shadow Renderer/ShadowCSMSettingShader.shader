// Unity built-in shader source. Copyright (c) 2016 Unity Technologies. MIT license (see license.txt)

// Collects cascaded shadows into screen space buffer
Shader "Hidden/ShadowSettingShader" {
Properties {
    _ShadowMapTexture ("", any) = "" {}
    _ODSWorldTexture("", 2D) = "" {}
}

CGINCLUDE

UNITY_DECLARE_SHADOWMAP(_ShadowMapTexture);
float4 _ShadowMapTexture_TexelSize;
#define SHADOWMAPSAMPLER_AND_TEXELSIZE_DEFINED
sampler2D _ODSWorldTexture;

#include "UnityCG.cginc"
#include "UnityShadowLibrary.cginc"
//#define UNITY_USE_RECEIVER_PLANE_BIAS


// Blend between shadow cascades to hide the transition seams?
#define UNITY_USE_CASCADE_BLENDING 0
#define UNITY_CASCADE_BLEND_DISTANCE 0.1


struct appdata {
    float4 vertex : POSITION;
    float2 texcoord : TEXCOORD0;
#ifdef UNITY_STEREO_INSTANCING_ENABLED
    float3 ray0 : TEXCOORD1;
    float3 ray1 : TEXCOORD2;
#else
    float3 ray : TEXCOORD1;
#endif
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

struct v2f {

    float4 pos : SV_POSITION;

    // xy uv / zw screenpos
    float4 uv : TEXCOORD0;
    // View space ray, for perspective case
    float3 ray : TEXCOORD1;
    // Orthographic view space positions (need xy as well for oblique matrices)
    float3 orthoPosNear : TEXCOORD2;
    float3 orthoPosFar  : TEXCOORD3;
    UNITY_VERTEX_INPUT_INSTANCE_ID
    UNITY_VERTEX_OUTPUT_STEREO
};

v2f vert (appdata v)
{
    v2f o;
    UNITY_SETUP_INSTANCE_ID(v);
    UNITY_TRANSFER_INSTANCE_ID(v, o);
    UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
    float4 clipPos;
#if defined(STEREO_CUBEMAP_RENDER_ON)
    clipPos = mul(UNITY_MATRIX_VP, mul(unity_ObjectToWorld, v.vertex));
#else
    clipPos = UnityObjectToClipPos(v.vertex);
#endif
    o.pos = clipPos;
    o.uv.xy = v.texcoord;

    // unity_CameraInvProjection at the PS level.
    o.uv.zw = ComputeNonStereoScreenPos(clipPos);

    // Perspective case
#ifdef UNITY_STEREO_INSTANCING_ENABLED
    o.ray = unity_StereoEyeIndex == 0 ? v.ray0 : v.ray1;
#else
    o.ray = v.ray;
#endif

    // To compute view space position from Z buffer for orthographic case,
    // we need different code than for perspective case. We want to avoid
    // doing matrix multiply in the pixel shader: less operations, and less
    // constant registers used. Particularly with constant registers, having
    // unity_CameraInvProjection in the pixel shader would push the PS over SM2.0
    // limits.
    clipPos.y *= _ProjectionParams.x;
    float3 orthoPosNear = mul(unity_CameraInvProjection, float4(clipPos.x,clipPos.y,-1,1)).xyz;
    float3 orthoPosFar  = mul(unity_CameraInvProjection, float4(clipPos.x,clipPos.y, 1,1)).xyz;
    orthoPosNear.z *= -1;
    orthoPosFar.z *= -1;
    o.orthoPosNear = orthoPosNear;
    o.orthoPosFar = orthoPosFar;

    return o;
}

// ------------------------------------------------------------------
//  Helpers
// ------------------------------------------------------------------
UNITY_DECLARE_DEPTH_TEXTURE(_CameraDepthTexture);
// sizes of cascade projections, relative to first one
float4 unity_ShadowCascadeScales;

//
// Keywords based defines
//
#if defined (SHADOWS_SPLIT_SPHERES)
    #define GET_CASCADE_WEIGHTS(wpos, z)    getCascadeWeights_splitSpheres(wpos)
#else
    #define GET_CASCADE_WEIGHTS(wpos, z)    getCascadeWeights( wpos, z )
#endif

#if defined (SHADOWS_SINGLE_CASCADE)
    #define GET_SHADOW_COORDINATES(wpos,cascadeWeights) getShadowCoord_SingleCascade(wpos)
#else
    #define GET_SHADOW_COORDINATES(wpos,cascadeWeights) getShadowCoord(wpos,cascadeWeights)
#endif

/**
 * Gets the cascade weights based on the world position of the fragment.
 * Returns a float4 with only one component set that corresponds to the appropriate cascade.
 */
inline fixed4 getCascadeWeights(float3 wpos, float z)
{
    fixed4 zNear = float4( z >= _LightSplitsNear );
    fixed4 zFar = float4( z < _LightSplitsFar );
    fixed4 weights = zNear * zFar;
    return weights;
}

/**
 * Gets the cascade weights based on the world position of the fragment and the poisitions of the split spheres for each cascade.
 * Returns a float4 with only one component set that corresponds to the appropriate cascade.
 */
inline fixed4 getCascadeWeights_splitSpheres(float3 wpos)
{
    float3 fromCenter0 = wpos.xyz - unity_ShadowSplitSpheres[0].xyz;
    float3 fromCenter1 = wpos.xyz - unity_ShadowSplitSpheres[1].xyz;
    float3 fromCenter2 = wpos.xyz - unity_ShadowSplitSpheres[2].xyz;
    float3 fromCenter3 = wpos.xyz - unity_ShadowSplitSpheres[3].xyz;
    float4 distances2 = float4(dot(fromCenter0,fromCenter0), dot(fromCenter1,fromCenter1), dot(fromCenter2,fromCenter2), dot(fromCenter3,fromCenter3));
    fixed4 weights = float4(distances2 < unity_ShadowSplitSqRadii);
    weights.yzw = saturate(weights.yzw - weights.xyz);
    return weights;
}

/**
 * Returns the shadowmap coordinates for the given fragment based on the world position and z-depth.
 * These coordinates belong to the shadowmap atlas that contains the maps for all cascades.
 */
inline float4 getShadowCoord( float4 wpos, fixed4 cascadeWeights )
{
    float3 sc0 = mul (unity_WorldToShadow[0], wpos).xyz;
    float3 sc1 = mul (unity_WorldToShadow[1], wpos).xyz;
    float3 sc2 = mul (unity_WorldToShadow[2], wpos).xyz;
    float3 sc3 = mul (unity_WorldToShadow[3], wpos).xyz;
    float4 shadowMapCoordinate = float4(sc0 * cascadeWeights[0] + sc1 * cascadeWeights[1] + sc2 * cascadeWeights[2] + sc3 * cascadeWeights[3], 1);
#if defined(UNITY_REVERSED_Z)
    float  noCascadeWeights = 1 - dot(cascadeWeights, float4(1, 1, 1, 1));
    shadowMapCoordinate.z += noCascadeWeights;
#endif
    return shadowMapCoordinate;
}

/**
 * Same as the getShadowCoord; but optimized for single cascade
 */
inline float4 getShadowCoord_SingleCascade( float4 wpos )
{
    return float4( mul (unity_WorldToShadow[0], wpos).xyz, 0);
}

/**
* Get camera space coord from depth and inv projection matrices
*/
inline float3 computeCameraSpacePosFromDepthAndInvProjMat(v2f i)
{
    float zdepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, i.uv.xy);

    #if defined(UNITY_REVERSED_Z)
        zdepth = 1 - zdepth;
    #endif

    // View position calculation for oblique clipped projection case.
    // this will not be as precise nor as fast as the other method
    // (which computes it from interpolated ray & depth) but will work
    // with funky projections.
    float4 clipPos = float4(i.uv.zw, zdepth, 1.0);
    clipPos.xyz = 2.0f * clipPos.xyz - 1.0f;
    float4 camPos = mul(unity_CameraInvProjection, clipPos);
    camPos.xyz /= camPos.w;
    camPos.z *= -1;
    return camPos.xyz;
}

/**
* Get camera space coord from depth and info from VS
*/
inline float3 computeCameraSpacePosFromDepthAndVSInfo(v2f i)
{
    float zdepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, i.uv.xy);

    // 0..1 linear depth, 0 at camera, 1 at far plane.
    float depth = lerp(Linear01Depth(zdepth), zdepth, unity_OrthoParams.w);
#if defined(UNITY_REVERSED_Z)
    zdepth = 1 - zdepth;
#endif

    // view position calculation for perspective & ortho cases
    float3 vposPersp = i.ray * depth;
    float3 vposOrtho = lerp(i.orthoPosNear, i.orthoPosFar, zdepth);
    // pick the perspective or ortho position as needed
    float3 camPos = lerp(vposPersp, vposOrtho, unity_OrthoParams.w);
    return camPos.xyz;
}

inline float3 computeCameraSpacePosFromDepth(v2f i);

/**
 *  Hard shadow
 */
fixed4 frag_hard (v2f i) : SV_Target
{
    UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

    float4 wpos;
    float3 vpos;

#if defined(STEREO_CUBEMAP_RENDER_ON)
    wpos.xyz = tex2D(_ODSWorldTexture, i.uv.xy).xyz;
    wpos.w = 1.0f;
    vpos = mul(unity_WorldToCamera, wpos).xyz;
#else
    vpos = computeCameraSpacePosFromDepth(i);
    wpos = mul(unity_CameraToWorld, float4(vpos,1));
#endif

    fixed4 cascadeWeights = GET_CASCADE_WEIGHTS(wpos, vpos.z);
    float4 shadowCoord = GET_SHADOW_COORDINATES(wpos, cascadeWeights);
    fixed shadow = UNITY_SAMPLE_SHADOW(_ShadowMapTexture, shadowCoord);

    return fixed4(shadow, shadow, shadow, 1);
}

/**
 * Soft Shadow with Rotated Poisson Disk Sampling and Cascade Blending
 */

// Define the number of samples. 16 is a good balance of quality and performance.
#define NUM_SAMPLES 16

// Pre-calculated Poisson Disk sample points (for NUM_SAMPLES = 16)
// These points are randomly distributed but maintain a minimum distance.
static const float2 POISSON_DISK_SAMPLES[NUM_SAMPLES] =
{
    float2(-0.94201624, -0.39906216), float2(0.94558609, -0.76890725),
    float2(-0.09418410, -0.92938870), float2(0.34495938, 0.29387760),
    float2(-0.91588581, 0.45771432), float2(-0.81544232, -0.87912464),
    float2(-0.38277543, 0.27676845), float2(0.97484398, 0.75648379),
    float2(0.44323325, -0.97511554), float2(0.53742981, -0.47373420),
    float2(-0.26496911, -0.41893023), float2(0.79197514, 0.19090188),
    float2(-0.24188840, 0.99706507), float2(-0.81409955, 0.91437590),
    float2(0.19984126, 0.78641367), float2(0.14383161, -0.14100790)
};

// Noise function
float random(float2 p)
{
    return frac(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453 +
                sin(dot(p, float2(56.789, 12.345))) * 23456.789);
}

// Renamed function back to frag_pcfSoft to match the #pragma directive in the Subshader passes.
fixed4 frag_pcfSoft(v2f i) : SV_Target
{
    UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);
    float4 wpos;
    float3 vpos;

#if defined(STEREO_CUBEMAP_RENDER_ON)
    wpos.xyz = tex2D(_ODSWorldTexture, i.uv.xy).xyz;
    wpos.w = 1.0f;
    vpos = mul(unity_WorldToCamera, wpos).xyz;
#else
    vpos = computeCameraSpacePosFromDepth(i);
    wpos = mul(unity_CameraToWorld, float4(vpos, 1));
#endif

    fixed4 cascadeWeights = GET_CASCADE_WEIGHTS(wpos, vpos.z);
    float4 coord = GET_SHADOW_COORDINATES(wpos, cascadeWeights);

    // --- Receiver Plane Bias Calculation ---
    float3 receiverPlaneDepthBias = 0.0;
#ifdef UNITY_USE_RECEIVER_PLANE_BIAS
    float3 coordCascade0 = getShadowCoord_SingleCascade(wpos);
    float biasMultiply = dot(cascadeWeights, unity_ShadowCascadeScales);
    receiverPlaneDepthBias = UnityGetReceiverPlaneDepthBias(coordCascade0.xyz, biasMultiply);
#endif

    // --- Rotated Poisson Disk Sampling ---

    // Get a random rotation angle based on the pixel's world position.
    float angle = random(wpos.xy) * 2.0 * UNITY_PI;
    float s, c;
    sincos(angle, s, c);
    float2x2 rotationMatrix = float2x2(c, -s, s, c);

    // Define the softness of the shadow.
    float _FilterRadius = 0.001;
    float radius = _FilterRadius * coord.w;

    float _ShadowDarkness = 2.5;

    half shadow = 0.0;
    UNITY_LOOP
    for (int j = 0; j < NUM_SAMPLES; ++j)
    {
        // Get the base rotated sample offset
        float2 offset = mul(rotationMatrix, POISSON_DISK_SAMPLES[j]);
        
        // Create the sample coordinate and sample the shadow map
        float4 sampleCoord = float4(coord.xy + offset * radius, coord.z, coord.w);
        shadow += UNITY_SAMPLE_SHADOW(_ShadowMapTexture, sampleCoord);
    }
    // Average the results
    shadow /= (half)NUM_SAMPLES;

    // --- Shadow Darkening ---
    shadow = pow(shadow, _ShadowDarkness);
    
    // The final shadow value.
    shadow = lerp(_LightShadowData.r, 1.0f, shadow);

    // --- Cascade Blending ---
#if UNITY_USE_CASCADE_BLENDING && !defined(SHADOWS_SPLIT_SPHERES) && !defined(SHADOWS_SINGLE_CASCADE)
    half4 z4 = (float4(vpos.z, vpos.z, vpos.z, vpos.z) - _LightSplitsNear) / (_LightSplitsFar - _LightSplitsNear);
    half alpha = dot(z4 * cascadeWeights, half4(1, 1, 1, 1));

    UNITY_BRANCH
    if (alpha > 1 - UNITY_CASCADE_BLEND_DISTANCE)
    {
        alpha = (alpha - (1 - UNITY_CASCADE_BLEND_DISTANCE)) / UNITY_CASCADE_BLEND_DISTANCE;

        // Get coordinates for the next cascade
        cascadeWeights = fixed4(0, cascadeWeights.xyz);
        float4 nextCoord = GET_SHADOW_COORDINATES(wpos, cascadeWeights);

#ifdef UNITY_USE_RECEIVER_PLANE_BIAS
        biasMultiply = dot(cascadeWeights, unity_ShadowCascadeScales);
        receiverPlaneDepthBias = UnityGetReceiverPlaneDepthBias(coordCascade0.xyz, biasMultiply);
#endif
        // --- Blending ---
        half shadowNextCascade = 0.0;
        float nextRadius = _FilterRadius * nextCoord.w;

        UNITY_LOOP
        for (int k = 0; k < NUM_SAMPLES; ++k)
        {
            float2 offset = mul(rotationMatrix, POISSON_DISK_SAMPLES[k]);
            
            float4 sampleCoord = float4(nextCoord.xy + offset * nextRadius, nextCoord.z, nextCoord.w);
            shadowNextCascade += UNITY_SAMPLE_SHADOW(_ShadowMapTexture, sampleCoord);
        }
        shadowNextCascade /= (half)NUM_SAMPLES;
        
        // Apply darkness to the blended cascade as well.
        shadowNextCascade = pow(shadowNextCascade, _ShadowDarkness);

        shadowNextCascade = lerp(_LightShadowData.r, 1.0f, shadowNextCascade);
        
        shadow = lerp(shadow, shadowNextCascade, alpha);
    }
#endif

    return shadow;
}
ENDCG

// ----------------------------------------------------------------------------------------
// Subshader for hard shadows:
// Just collect shadows into the buffer. Used on pre-SM3 GPUs and when hard shadows are picked.

SubShader {
    Tags{ "ShadowmapFilter" = "HardShadow" }
    Pass {
        ZWrite Off ZTest Always Cull Off

        CGPROGRAM
        #pragma vertex vert
        #pragma fragment frag_hard
        #pragma multi_compile_shadowcollector

        inline float3 computeCameraSpacePosFromDepth(v2f i)
        {
            return computeCameraSpacePosFromDepthAndVSInfo(i);
        }
        ENDCG
    }
}

// ----------------------------------------------------------------------------------------
// Subshader for hard shadows:
// Just collect shadows into the buffer. Used on pre-SM3 GPUs and when hard shadows are picked.
// This version does inv projection at the PS level, slower and less precise however more general.

SubShader {
    Tags{ "ShadowmapFilter" = "HardShadow_FORCE_INV_PROJECTION_IN_PS" }
    Pass{
        ZWrite Off ZTest Always Cull Off

        CGPROGRAM
        #pragma vertex vert
        #pragma fragment frag_hard
        #pragma multi_compile_shadowcollector

        inline float3 computeCameraSpacePosFromDepth(v2f i)
        {
            return computeCameraSpacePosFromDepthAndInvProjMat(i);
        }
        ENDCG
    }
}

// ----------------------------------------------------------------------------------------
// Subshader that does soft PCF filtering while collecting shadows.
// Requires SM3 GPU.

Subshader {
    Tags {"ShadowmapFilter" = "PCF_SOFT"}
    Pass {
        ZWrite Off ZTest Always Cull Off

        CGPROGRAM
        #pragma vertex vert
        #pragma fragment frag_pcfSoft
        #pragma multi_compile_shadowcollector
        #pragma target 3.0

        inline float3 computeCameraSpacePosFromDepth(v2f i)
        {
            return computeCameraSpacePosFromDepthAndVSInfo(i);
        }
        ENDCG
    }
}

// ----------------------------------------------------------------------------------------
// Subshader that does soft PCF filtering while collecting shadows.
// Requires SM3 GPU.
// This version does inv projection at the PS level, slower and less precise however more general.

Subshader{
    Tags{ "ShadowmapFilter" = "PCF_SOFT_FORCE_INV_PROJECTION_IN_PS" }
    Pass{
        ZWrite Off ZTest Always Cull Off

        CGPROGRAM
        #pragma vertex vert
        #pragma fragment frag_pcfSoft
        #pragma multi_compile_shadowcollector
        #pragma target 3.0

        inline float3 computeCameraSpacePosFromDepth(v2f i)
        {
            return computeCameraSpacePosFromDepthAndInvProjMat(i);
        }
        ENDCG
    }
}

Fallback Off
}
