Shader "YmneShader/PBR_GGX_Deferred_Opaque"
{
    Properties
    {
        // -- - Rendering and Opacity -- -
        [Header(Rendering and Opacity)]
        [Enum(Off, 0, Front, 1, Back, 2)] _Culling ("Culling", Float) = 2.0
        [Toggle(_CUTOUT_ON)] _UseCutout ("Enable Alpha Cutout", Float) = 0.0
        _Cutoff ("Alpha Cutoff", Range(0.0, 1.0)) = 0.5

        // -- - Primary Surface Maps -- -
        [Space(10)] [Header(Primary Surface Maps)]
        _Color ("Color", Color) = (1, 1, 1, 1)
        _MainTex ("Albedo (RGB) & Alpha (A)", 2D) = "white" {}
        [NoScaleOffset] _NormalMap ("Normal Map", 2D) = "bump" {}
        _BumpScale ("Normal Intensity", Float) = 1.0
        [NoScaleOffset] _MetallicMap ("Metallic Map (R)", 2D) = "white" {}
        _Metallic ("Metallic", Range(0, 1)) = 0.0
        [NoScaleOffset] _RoughnessMap ("Roughness Map (R)", 2D) = "white" {}
        _Roughness ("Roughness", Range(0, 1)) = 0.5
        [NoScaleOffset] _OcclusionMap ("Occlusion Map (G)", 2D) = "white" {}
        _OcclusionStrength ("Occlusion Strength", Float) = 1.0
        _SpecularIntensity ("Specular Intensity", Range(0, 1)) = 1.0

        // -- - Parallax Occlusion Mapping (Displacement) -- -
        [Space(10)] [Header(Parallax Occlusion Mapping)]
        [Toggle(_USEPOM_ON)] _UsePOM ("Enable", Float) = 0.0
        [NoScaleOffset] _ParallaxMap ("Height Map (R)", 2D) = "black" {}
        _Parallax ("Height Scale", Float) = 0.025
        _POMSamples ("POM Samples", Range(0, 64)) = 8.0
        _POMRefinementSteps ("POM Refinement Steps", Range(0, 64)) = 2.0
        [Space(5)]
        _POMShadowIntensity ("Shadow Intensity", Range(0, 1)) = 1.0
        _POMShadowSoftness ("Shadow Softness", Range(0, 1)) = 0.25
        _POMShadowDistance ("Shadow Distance", Range(0, 5)) = 1.0
        _POMShadowSamples ("Shadow Samples", Range(0, 64)) = 8.0
        _POMShadowThreshold ("Shadow Threshold", Range(0, 0.1)) = 0.01

        // -- - Detail Mapping -- -
        [Space(10)] [Header(Detail Mapping)]
        [NoScaleOffset] _DetailAlbedoMap ("Detail Albedo (RGB)", 2D) = "gray" {}
        _DetailAlbedoIntensity("Detail Albedo Intensity", Range(0, 1)) = 0.0
        [NoScaleOffset] _DetailNormalMap ("Detail Normal Map", 2D) = "bump" {}
        _DetailMapTiling ("Detail Map Tiling", Float) = 1.0
        _DetailNormalScale ("Detail Normal Scale", Float) = 1.0

        // -- - Advanced Effects -- -
        [Space(10)] [Header(Advanced Effects)]

        // Emission
        [Space(5)] [Header(Emission)]
        [NoScaleOffset] _EmissionMap ("Emission Map (RGB)", 2D) = "white" {}
        [HDR] _EmissionColor ("Color", Color) = (1, 1, 1, 1)
        _EmissionIntensity ("Intensity", Float) = 0.0

        // Rim Lighting
        [Space(5)] [Header(Rim Lighting)]
        [HDR] _RimColor ("Color", Color) = (1, 1, 1, 1)
        _RimPower ("Power", Range(0.0, 10)) = 0.0
        _RimIntensity ("Intensity", Float) = 0.0

        // Subsurface Scattering
        [Space(5)] [Header(Subsurface Scattering)]
        [Toggle(_USESS_ON)] _UseSSS ("Enable", Float) = 0.0
        [NoScaleOffset] _SubsurfaceDataMap ("Mask (R) & Thickness (G)", 2D) = "white" {}
        _SubsurfaceColor ("Color", Color) = (1, 0.7725, 0.2705, 1)
        _SubsurfaceIntensity ("Intensity", Float) = 1.00
        _SubsurfaceRadius ("Scatter Falloff", Range(0, 1)) = 0.075
        _ScatterDistance ("Scatter Distance", Range(0, 5)) = 0.75
        _ThicknessScale ("Thickness Scale", Range(0, 10)) = 1.0

    }
    SubShader
    {
        Tags { "RenderType" = "Opaque" "Queue" = "Geometry" }
        LOD 200

        Cull [_Culling]

        CGPROGRAM
        #pragma surface surf Standard deferred vertex:vert
        #pragma target 5.0
        #pragma multi_compile_instancing
        #pragma multi_compile __ _CUTOUT_ON

        #pragma shader_feature _USEPOM_ON
        #pragma shader_feature _USESS_ON

        #include "UnityPBSLighting.cginc"

        // Variable Declarations
        sampler2D _MainTex, _NormalMap, _MetallicMap, _RoughnessMap, _OcclusionMap,
        _ParallaxMap, _SubsurfaceDataMap, _EmissionMap,
        _DetailAlbedoMap, _DetailNormalMap;
        float4 _MainTex_ST;

        float _Culling;
        half _Roughness, _Metallic, _BumpScale, _OcclusionStrength,
        _Parallax, _POMSamples, _POMRefinementSteps, _POMShadowIntensity, _Cutoff, _SpecularIntensity;
        half _POMShadowSamples, _POMShadowThreshold, _POMShadowDistance, _POMShadowSoftness;
        half _SubsurfaceRadius, _ThicknessScale, _SubsurfaceIntensity, _ScatterDistance;
        half _EmissionIntensity;
        half _DetailMapTiling, _DetailNormalScale, _DetailAlbedoIntensity;
        half _RimPower, _RimIntensity;
        fixed4 _Color, _SubsurfaceColor, _EmissionColor, _RimColor;

        struct Input
        {
            float2 customTiledUV;
            float3 viewDir;
            float3 lightDir;
            float vface : VFACE;
            float3 worldPos;
        };

        // Reoriented Normal Mapping helper for detail maps
        half3 Custom_BlendNormals(half3 baseNormal, half3 detailNormal)
        {
            baseNormal += half3(0, 0, 1);
            detailNormal *= half3(- 1, - 1, 1);
            return baseNormal * dot(baseNormal, detailNormal) / baseNormal.z - detailNormal;
        }

        half3 CalculateSubsurfaceScattering(Input IN, half3 normal, half3 albedo, half thickness)
        {
            // -- - Inputs -- -
            half3 lightDir = normalize(IN.lightDir);
            half3 viewDir = normalize(IN.viewDir);

            // -- - Forward Scattering (Light wrapping) -- -
            half3 distortedNormal = normalize(normal - viewDir * thickness * _SubsurfaceRadius);

            // Calculate the lighting with this new, distorted normal.
            half wrap = saturate(dot(distortedNormal, lightDir));

            // -- - Back Scattering (Translucency) -- -
            half backscatter = saturate(dot(viewDir, - lightDir));
            // _ScatterDistance controls the tightness of the glow.
            backscatter = pow(backscatter, _ScatterDistance * 5.0h);

            // -- - Combine and Modulate -- -
            half sss = (wrap + backscatter) * 0.5h; // Average the two effects

            // Modulate the result by the subsurface color, albedo, thickness, and overall intensity.
            half3 finalSSS = sss * thickness * _SubsurfaceColor.rgb * albedo;
            finalSSS *= _SubsurfaceIntensity;

            return finalSSS;
        }

        // Vertex Function - Used to pass world - space data to the fragment shader
        void vert (inout appdata_full v, out Input o)
        {
            UNITY_SETUP_INSTANCE_ID(v);
            UNITY_INITIALIZE_OUTPUT(Input, o);
            o.customTiledUV = v.texcoord.xy * _MainTex_ST.xy + _MainTex_ST.zw;
            TANGENT_SPACE_ROTATION;
            o.viewDir = mul(rotation, ObjSpaceViewDir(v.vertex));
            o.lightDir = mul(rotation, ObjSpaceLightDir(v.vertex));
            o.worldPos = mul(unity_ObjectToWorld, v.vertex).xyz;
        }

        // Surface Function
        void surf (Input IN, inout SurfaceOutputStandard o)
        {
            float2 uv = IN.customTiledUV;
            half pom_shadow = 1.0;

            #if defined(_USEPOM_ON)
            // Parallax Occlusion Mapping (POM)
            float3 viewDir = normalize(IN.viewDir);
            float stepSize = 1.0 / _POMSamples;
            float2 uvStep = - ((viewDir.xy * _Parallax) * stepSize);

            float2 currentUV = IN.customTiledUV;
            float currentHeight = 1.0;

            // Use ddx / ddy for mip - mapping with POM to avoid artifacts
            float2 ddx_uv = ddx(IN.customTiledUV);
            float2 ddy_uv = ddy(IN.customTiledUV);

            // Raymarching loop for height intersection
            [loop]
            for (int i = 0; i < _POMSamples; i ++)
            {
                currentHeight -= stepSize;
                currentUV += uvStep;
                float sampledHeight = tex2Dgrad(_ParallaxMap, currentUV, ddx_uv, ddy_uv).r;
                if (sampledHeight > currentHeight)
                {
                    // Refinement Step - binary search to find a more precise intersection
                    float2 frontUV = currentUV - uvStep;
                    float2 backUV = currentUV;
                    float frontRayHeight = currentHeight + stepSize;
                    float backRayHeight = currentHeight;

                    int numRefinementSteps = (int)_POMRefinementSteps;
                    [loop]
                    for (int k = 0; k < numRefinementSteps; k ++)
                    {
                        float2 midUV = (frontUV + backUV) * 0.5;
                        float midRayHeight = (frontRayHeight + backRayHeight) * 0.5;
                        float midSampledHeight = tex2Dgrad(_ParallaxMap, midUV, ddx_uv, ddy_uv).r;
                        if (midSampledHeight > midRayHeight) {
                            backUV = midUV;
                            backRayHeight = midRayHeight;
                        } else {
                            frontUV = midUV;
                            frontRayHeight = midRayHeight;
                        }
                    }
                    currentUV = (frontUV + backUV) * 0.5;
                    currentHeight = (frontRayHeight + backRayHeight) * 0.5;
                    break;
                }
            }
            uv = currentUV;

            // POM Self - Shadowing with Softness
            float3 lightDir = normalize(IN.lightDir);
            float shadowStep = 1.0 / _POMShadowSamples;
            float2 shadowUVStep = ((lightDir.xy * _Parallax * _POMShadowDistance) * shadowStep);

            float2 shadowUV = uv;
            float shadowHeight = currentHeight;
            float totalShadow = 0.0;
            int shadowsFound = 0;

            [loop]
            for (int j = 1; j < (int)_POMShadowSamples; j ++)
            {
                shadowHeight += shadowStep;
                shadowUV += shadowUVStep;
                float sampledHeight = tex2Dgrad(_ParallaxMap, shadowUV, ddx_uv, ddy_uv).r;
                if (sampledHeight > shadowHeight + _POMShadowThreshold)
                {
                    float penumbra = saturate((sampledHeight - shadowHeight) / (_POMShadowSoftness + 0.0001));
                    totalShadow += penumbra;
                    shadowsFound ++;
                }
            }

            if (shadowsFound > 0)
            {
                pom_shadow = 1.0 - saturate((totalShadow / shadowsFound) * _POMShadowIntensity);
            }
            #endif

            float roughnessMapValue = tex2D(_RoughnessMap, uv).r;
            float effectiveRoughness = roughnessMapValue * (_Roughness * 2.5);

            // Albedo & Alpha
            fixed4 c = tex2D(_MainTex, uv) * _Color;
            half alpha = c.a;

            #if defined(_CUTOUT_ON)
            clip(alpha - _Cutoff);
            #endif

            o.Albedo = c.rgb;

            // Detail Mapping
            float2 detailUV = uv * _DetailMapTiling;
            half3 detailAlbedo = tex2D(_DetailAlbedoMap, detailUV).rgb;
            o.Albedo = lerp(o.Albedo, o.Albedo * detailAlbedo * 2, _DetailAlbedoIntensity);

            // Apply POM self - shadowing to albedo
            o.Albedo *= pom_shadow;

            // Normal Mapping
            half3 normal = UnpackScaleNormal(tex2D(_NormalMap, uv), _BumpScale);

            // Detail Normal Map Blending
            half3 detailNormal = UnpackScaleNormal(tex2D(_DetailNormalMap, detailUV), _DetailNormalScale);
            normal = Custom_BlendNormals(normal, detailNormal);

            o.Normal = normalize(normal);
            // vface for culling in case Culling is set to 0 (Off)
            if (_Culling == 0) {
                o.Normal *= IN.vface;
            }


            o.Metallic = tex2D(_MetallicMap, uv).r * _Metallic;
            // Use the 'effectiveRoughness' on this line to ensure roughness from texture is respected
            o.Smoothness = (1.0 - effectiveRoughness) * _SpecularIntensity;
            o.Occlusion = lerp(1, tex2D(_OcclusionMap, uv).g, _OcclusionStrength);

            // Emission & Subsurface Scattering
            fixed3 emission_color = 0;

            // Emission is now always calculated, but its contribution is zero if _EmissionIntensity is 0.
            emission_color += tex2D(_EmissionMap, uv).rgb * _EmissionColor.rgb * _EmissionIntensity;

            #if defined(_USESS_ON)
            half2 sssData = tex2D(_SubsurfaceDataMap, uv).rg; // r : mask, g : thickness
            half sssMask = sssData.r;
            half thickness = sssData.g * _ThicknessScale;

            half3 subsurface = CalculateSubsurfaceScattering(IN, normal, o.Albedo, thickness);

            // Energy Conservation : Reduce base albedo slightly based on SSS mask and color alpha
            o.Albedo *= (1.0 - sssMask * _SubsurfaceColor.a * 0.5);
            emission_color += subsurface * sssMask;
            #endif

            // Rim Lighting
            half rim = 1.0 - saturate(dot(o.Normal, normalize(IN.viewDir))); // Calculate rim based on surface normal and view direction
            rim = pow(rim, _RimPower);
            emission_color += _RimColor.rgb * rim * _RimIntensity; // Add rim contribution to emission

            o.Emission = emission_color;

            o.Alpha = 1.0;
        }
        ENDCG

        // Shadow Caster Pass
        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }

            ZWrite On
            ZTest LEqual
            Cull [_Culling]

            CGPROGRAM
            #pragma vertex vert_shadow
            #pragma fragment frag_shadow
            #pragma multi_compile_shadowcaster
            #pragma shader_feature _CUTOUT_ON
            #pragma shader_feature _USEPOM_ON

            #include "UnityCG.cginc"

            struct v2f_shadow
            {
                V2F_SHADOW_CASTER;
                float2 uv : TEXCOORD1;
                float3 viewDir : TEXCOORD2;
            };

            sampler2D _MainTex, _ParallaxMap;
            float4 _MainTex_ST;
            fixed4 _Color;
            half _Cutoff, _Parallax, _POMSamples, _POMRefinementSteps;

            v2f_shadow vert_shadow(appdata_full v)
            {
                v2f_shadow o;
                UNITY_INITIALIZE_OUTPUT(v2f_shadow, o);
                TRANSFER_SHADOW_CASTER_NORMALOFFSET(o)
                o.uv = v.texcoord.xy * _MainTex_ST.xy + _MainTex_ST.zw;

                TANGENT_SPACE_ROTATION;
                o.viewDir = mul(rotation, ObjSpaceViewDir(v.vertex));
                return o;
            }

            fixed4 frag_shadow(v2f_shadow i) : SV_Target
            {
                float2 uv = i.uv;

                #if defined(_USEPOM_ON)
                // POM for shadow casting pass
                float3 viewDir = normalize(i.viewDir);
                float stepSize = 1.0 / _POMSamples;
                float2 uvStep = - ((viewDir.xy * _Parallax) * stepSize);

                float2 currentUV = i.uv;
                float currentHeight = 1.0;

                float2 ddx_uv = ddx(i.uv);
                float2 ddy_uv = ddy(i.uv);

                [loop]
                for (int pom_i = 0; pom_i < _POMSamples; pom_i ++)
                {
                    currentHeight -= stepSize;
                    currentUV += uvStep;
                    float sampledHeight = tex2Dgrad(_ParallaxMap, currentUV, ddx_uv, ddy_uv).r;

                    if (sampledHeight > currentHeight)
                    {
                        float2 frontUV = currentUV - uvStep;
                        float2 backUV = currentUV;
                        float frontRayHeight = currentHeight + stepSize;
                        float backRayHeight = currentHeight;

                        int numRefinementSteps = (int)_POMRefinementSteps;
                        [loop]
                        for (int k = 0; k < numRefinementSteps; k ++)
                        {
                            float2 midUV = (frontUV + backUV) * 0.5;
                            float midRayHeight = (frontRayHeight + backRayHeight) * 0.5;
                            float midSampledHeight = tex2Dgrad(_ParallaxMap, midUV, ddx_uv, ddy_uv).r;
                            if (midSampledHeight > midRayHeight) {
                                backUV = midUV; backRayHeight = midRayHeight;
                            } else {
                                frontUV = midUV; frontRayHeight = midRayHeight;
                            }
                        }
                        currentUV = (frontUV + backUV) * 0.5;
                        break;
                    }
                }
                uv = currentUV; // Use the displaced UV
                #endif

                fixed4 tex = tex2D(_MainTex, uv) * _Color;
                half alpha = tex.a;

                #if defined(_CUTOUT_ON)
                clip(alpha - _Cutoff);
                #endif

                SHADOW_CASTER_FRAGMENT(i)
            }
            ENDCG
        }

        // Meta Pass for Lightmapping & Reflections
        Pass
        {
            Name "Meta"
            Tags { "LightMode" = "Meta" }

            Cull Off

            CGPROGRAM
            #pragma vertex vert_meta
            #pragma fragment frag_meta
            #pragma shader_feature _CUTOUT_ON

            #include "UnityCG.cginc"
            #include "UnityMetaPass.cginc"

            sampler2D _MainTex, _EmissionMap, _NormalMap;
            float4 _MainTex_ST;
            fixed4 _Color, _EmissionColor;
            half _EmissionIntensity, _Cutoff;
            float _BumpScale;

            struct v2f_meta
            {
                float4 pos : SV_POSITION;
                float2 uv : TEXCOORD0;
                float3 TtoW0 : TEXCOORD1;
                float3 TtoW1 : TEXCOORD2;
                float3 TtoW2 : TEXCOORD3;
            };

            v2f_meta vert_meta(appdata_full v)
            {
                v2f_meta o;
                o.pos = UnityMetaVertexPosition(v.vertex, v.texcoord1.xy, v.texcoord2.xy, unity_LightmapST, unity_DynamicLightmapST);
                o.uv = v.texcoord.xy * _MainTex_ST.xy + _MainTex_ST.zw;

                float3 worldPos = mul(unity_ObjectToWorld, v.vertex).xyz;
                float3 worldNormal = UnityObjectToWorldNormal(v.normal);
                float3 worldTangent = UnityObjectToWorldDir(v.tangent.xyz);
                float3 worldBinormal = cross(worldNormal, worldTangent) * v.tangent.w;

                o.TtoW0 = float3(worldTangent.x, worldBinormal.x, worldNormal.x);
                o.TtoW1 = float3(worldTangent.y, worldBinormal.y, worldNormal.y);
                o.TtoW2 = float3(worldTangent.z, worldBinormal.z, worldNormal.z);

                return o;
            }

            inline half3 UnpackNormal_Meta(half4 packednormal)
            {
                #if defined(UNITY_NO_DXT5nm)
                return packednormal.xyz * 2 - 1;
                #else
                half3 normal;
                normal.xy = packednormal.wy * 2 - 1;
                normal.z = sqrt(1.0 - saturate(dot(normal.xy, normal.xy)));
                return normal;
                #endif
            }

            inline half3 UnpackScaleNormal_Meta(half4 packednormal, half bumpScale)
            {
                half3 normal = UnpackNormal_Meta(packednormal);
                normal.xy *= bumpScale;
                normal.z = sqrt(1.0 - saturate(dot(normal.xy, normal.xy)));
                return normal;
            }

            struct frag_meta_out
            {
                half4 Albedo : SV_Target0;
                half4 Normal : SV_Target1;
            };

            frag_meta_out frag_meta(v2f_meta i)
            {
                UnityMetaInput metaIN;
                UNITY_INITIALIZE_OUTPUT(UnityMetaInput, metaIN);

                fixed4 albedo = tex2D(_MainTex, i.uv) * _Color;
                #if defined(_CUTOUT_ON)
                half alpha = albedo.a;
                clip(alpha - _Cutoff);
                #endif
                metaIN.Albedo = albedo.rgb;

                metaIN.Emission = tex2D(_EmissionMap, i.uv).rgb * _EmissionColor.rgb * _EmissionIntensity;

                half3 tangentNormal = UnpackScaleNormal_Meta(tex2D(_NormalMap, i.uv), _BumpScale);
                half3 worldNormal = half3(dot(i.TtoW0, tangentNormal), dot(i.TtoW1, tangentNormal), dot(i.TtoW2, tangentNormal));
                worldNormal = normalize(worldNormal);

                frag_meta_out o;
                o.Albedo = UnityMetaFragment(metaIN);
                o.Normal = half4(worldNormal * 0.5 + 0.5, 1);

                return o;
            }
            ENDCG
        }
    }
    FallBack "Diffuse"
    CustomEditor "ShaderForgeMaterialInspector"
}
