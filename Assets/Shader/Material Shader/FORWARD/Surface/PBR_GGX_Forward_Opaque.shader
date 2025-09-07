Shader "YmneShader/PBR_GGX_Forward_Opaque"
{
    Properties
    {
        // --- Rendering and Opacity ---
        [Header(Rendering and Opacity)]
        [Enum(Off, 0, Front, 1, Back, 2)] _Culling ("Culling", Float) = 2.0
        [Toggle(_CUTOUT_ON)] _UseCutout ("Enable Alpha Cutout", Float) = 0.0
        _Cutoff ("Alpha Cutoff", Range(0.0, 1.0)) = 0.5

        // --- Primary Surface Maps ---
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
        _DielectricF0 ("Dielectric Reflectance", Color) = (0.04, 0.04, 0.04, 1)

        // --- Parallax Occlusion Mapping (Displacement) ---
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

        // --- Detail Mapping ---
        [Space(10)] [Header(Detail Mapping)]
        [NoScaleOffset] _DetailAlbedoMap ("Detail Albedo (RGB)", 2D) = "gray" {}
        _DetailAlbedoIntensity("Detail Albedo Intensity", Range(0,1)) = 0.0
        [NoScaleOffset] _DetailNormalMap ("Detail Normal Map", 2D) = "bump" {}
        _DetailMapTiling ("Detail Map Tiling", Float) = 1.0
        _DetailNormalScale ("Detail Normal Scale", Float) = 1.0

        // --- Advanced Effects ---
        [Space(10)] [Header(Advanced Effects)]
        // Clear Coat
        [Space(5)] [Header(Clear Coat)]
        [NoScaleOffset] _ClearCoatMask ("Clear Coat Mask (R)", 2D) = "white" {}
        _ClearCoat ("Intensity", Range(0, 1)) = 0.0
        _ClearCoatRoughness ("Roughness", Range(0, 1)) = 1.0
        
        // Anisotropy
        [Space(5)] [Header(Anisotropy)]
        _Anisotropy ("Anisotropy", Range(-1, 1)) = 0.0

        // Emission
        [Space(5)] [Header(Emission)]
        [NoScaleOffset] _EmissionMap ("Emission Map (RGB)", 2D) = "white" {}
        [HDR] _EmissionColor ("Color", Color) = (1,1,1,1)
        _EmissionIntensity ("Intensity", Float) = 0.0

        // Rim Lighting
        [Space(5)] [Header(Rim Lighting)]
        [HDR] _RimColor ("Color", Color) = (1,1,1,1)
        _RimPower ("Power", Range(0.0, 10)) = 0.0
        _RimIntensity ("Intensity", Float) = 0.0

        // Specular Anti-Aliasing
        [Space(5)] [Header(Specular AA)]
        _ToksvigStrength ("Strength", Range(0, 1)) = 0.025

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
        Tags { "RenderType"="Opaque" "Queue"="Geometry" }
        LOD 200

        Cull [_Culling]

        CGPROGRAM
        #pragma surface surf CustomPBR fullforwardshadows addshadow vertex:vert
        #pragma target 5.0
        #pragma multi_compile_instancing

        // Use multi_compile for core features to speed up editor compilation
        #pragma multi_compile __ _CUTOUT_ON

        // Use shader_feature for expensive features that can be toggled off
        #pragma shader_feature _USEPOM_ON
        #pragma shader_feature _USESS_ON

        #include "UnityPBSLighting.cginc"

        // Variable Declarations
        sampler2D _MainTex, _NormalMap, _MetallicMap, _RoughnessMap, _OcclusionMap,
        _ParallaxMap, _SubsurfaceDataMap, _EmissionMap,
        _DetailAlbedoMap, _DetailNormalMap, _ClearCoatMask;
        float4 _MainTex_ST;

        float _Culling;
        half _Roughness, _Metallic, _BumpScale, _OcclusionStrength,
        _Parallax, _POMSamples, _POMRefinementSteps, _POMShadowIntensity, _Cutoff, _SpecularIntensity;
        half _POMShadowSamples, _POMShadowThreshold, _POMShadowDistance, _POMShadowSoftness;
        half _SubsurfaceRadius, _ThicknessScale, _SubsurfaceIntensity, _ScatterDistance;
        half _EmissionIntensity;
        half _ToksvigStrength;
        half _DetailMapTiling, _DetailNormalScale, _DetailAlbedoIntensity;
        half _Anisotropy;
        half _ClearCoat, _ClearCoatRoughness;
        half _RimPower, _RimIntensity;
        fixed4 _Color, _SubsurfaceColor, _EmissionColor, _DielectricF0, _RimColor;

        struct SurfaceOutputCustom
        {
            fixed3 Albedo;
            fixed3 Normal;
            fixed3 Emission;
            half Metallic;
            half Smoothness;
            half Occlusion;
            fixed Alpha;
            float3 WorldPos;
            half DirectShadow;
            float2 UV;
            half ClearCoat;
            half ClearCoatRoughness;
            half3 Tangent;
            half3 Binormal;
        };
        
        // Anisotropic GGX Distribution (Walter et al.)
        float D_GGX_Aniso(float NdotH, float HdotT, float HdotB, float ax, float ay)
        {
            float HdotT2 = HdotT * HdotT;
            float HdotB2 = HdotB * HdotB;
            float NdotH2 = NdotH * NdotH;
            float den_term = (HdotT2 / (ax * ax)) + (HdotB2 / (ay * ay)) + NdotH2;
            return 1.0 / (UNITY_PI * ax * ay * den_term * den_term);
        }

        // Isotropic GGX Distribution
        inline half D_GGX(half NdotH, half roughness)
        {
            half a = roughness * roughness;
            half a2 = a * a;
            half NdotH2 = NdotH * NdotH;
            half d = (NdotH2 * (a2 - 1.0) + 1.0);
            return a2 / (UNITY_PI * d * d);
        }

        // Smith-Schlick Geometry Term
        inline half G_SchlickGGX(half NdotV, half roughness)
        {
            half r = roughness + 1.0;
            half k = (r * r) / 8.0;
            return NdotV / (NdotV * (1.0 - k) + k);
        }

        inline half G_Smith(half NdotV, half NdotL, half roughness)
        {
            half ggx1 = G_SchlickGGX(NdotL, roughness);
            half ggx2 = G_SchlickGGX(NdotV, roughness);
            return ggx1 * ggx2;
        }

        // Schlick Fresnel
        inline half3 F_Schlick(half cosTheta, half3 F0)
        {
            return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
        }

        // Disney Diffuse Model
        inline half Fd_Disney(half NdotV, half NdotL, half LdotH, half roughness)
        {
            half Fd90 = 0.5 + 2.0 * LdotH * LdotH * (roughness * roughness);
            half lightScatter = (1.0 + (Fd90 - 1.0) * pow(1.0 - NdotL, 1.0));
            half viewScatter = (1.0 + (Fd90 - 1.0) * pow(1.0 - NdotV, 1.0));
            return lightScatter * viewScatter;
        }

        // Main PBR Lighting Function
        half4 LightingCustomPBR(SurfaceOutputCustom s, half3 viewDir, UnityGI gi)
        {
            half3 N = s.Normal;
            half3 V = viewDir;
            half roughness = 1.0 - s.Smoothness;

            // Specular AA: Modify roughness based on normal map variance
            float2 duv_dx = ddx(s.UV);
            float2 duv_dy = ddy(s.UV);
            half3 dN_dx = UnpackScaleNormal(tex2Dgrad(_NormalMap, s.UV, duv_dx, duv_dy), _BumpScale) - N;
            half3 dN_dy = UnpackScaleNormal(tex2Dgrad(_NormalMap, s.UV, duv_dx, duv_dy), _BumpScale) - N;
            half variance = dot(dN_dx, dN_dx) + dot(dN_dy, dN_dy);
            roughness = saturate(roughness + variance * _ToksvigStrength);
            
            roughness = max(roughness, 0.001h);

            half3 albedo = s.Albedo;
            half metallic = s.Metallic;

            // Direct Lighting Calculation
            half3 L = gi.light.dir;
            half3 H = normalize(V + L);
            half NdotL = saturate(dot(N, L));
            half NdotV = abs(dot(N, V));
            half NdotH = saturate(dot(N, H));
            half LdotH = saturate(dot(L, H));
            half VdotH = saturate(dot(V, H));

            // Specular Term (Anisotropic)
            // We use roughness^2 for a more perceptually linear response, which appears sharper.
            half perceptual_roughness = roughness * roughness;
            half HdotT = dot(H, s.Tangent);
            half HdotB = dot(H, s.Binormal);
            half aniso = _Anisotropy;
            half aspect = sqrt(1.0h - aniso * 0.9h);
            half ax = perceptual_roughness / aspect;
            half ay = perceptual_roughness * aspect;
            half D = D_GGX_Aniso(NdotH, HdotT, HdotB, ax, ay);
            
            half G = G_Smith(NdotV, NdotL, roughness);
            half3 F0_dielectric_val = _DielectricF0.rgb;
            half3 F = F_Schlick(VdotH, lerp(F0_dielectric_val, albedo, metallic));

            half3 specular = (D * G * F) / (4.0 * NdotV * NdotL + 0.001);

            // Diffuse Term
            half3 kS = F;
            half3 kD = (half3(1.0, 1.0, 1.0) - kS) * (1.0 - metallic);
            half disneyDiffuse = Fd_Disney(NdotV, NdotL, LdotH, roughness);
            half3 diffuse = disneyDiffuse * kD * albedo / UNITY_PI;
            diffuse *= s.Occlusion;

            // Combine Direct Lighting
            half3 directColor = (diffuse + specular) * gi.light.color * NdotL * s.DirectShadow;

            // Indirect Lighting Calculation
            half3 kS_indirect = F_Schlick(NdotV, lerp(F0_dielectric_val, albedo, metallic));
            half3 kD_indirect = (1.0 - kS_indirect) * (1.0 - metallic);
            half3 indirectDiffuse = gi.indirect.diffuse * albedo * kD_indirect;
            half3 reflection = gi.indirect.specular;
            half3 indirectSpecular = reflection * kS_indirect;

            // Final Color Composition (Base Layer)
            half3 finalColor = directColor + indirectDiffuse + indirectSpecular;

            // Clear Coat Layer
            half coatRoughness = s.ClearCoatRoughness;
            coatRoughness = max(coatRoughness, 0.001h);
            half D_coat = D_GGX(NdotH, coatRoughness);
            half G_coat = G_Smith(NdotV, NdotL, coatRoughness);
            half3 F_coat = F_Schlick(VdotH, 0.04);
            half3 specularCoat = (D_coat * G_coat * F_coat) / (4.0 * NdotV * NdotL + 0.001);
            
            half3 directCoat = specularCoat * gi.light.color * NdotL * s.DirectShadow;
            half3 indirectCoat = gi.indirect.specular * F_Schlick(NdotV, 0.04);

            half coatFresnel = F_Schlick(NdotL, 0.04).r;
            finalColor = lerp(finalColor, 0, coatFresnel * s.ClearCoat);
            finalColor += (directCoat + indirectCoat) * s.ClearCoat;

            // Rim Lighting
            half rim = 1.0 - saturate(dot(N, V));
            rim = pow(rim, _RimPower);
            finalColor += _RimColor.rgb * rim * _RimIntensity * gi.light.color * NdotL;

            finalColor += s.Emission;
            return half4(finalColor, s.Alpha);
        }

        // Global Illumination Function
        void LightingCustomPBR_GI(SurfaceOutputCustom s, UnityGIInput data, inout UnityGI gi)
        {
            half3 F0 = lerp(_DielectricF0.rgb, s.Albedo, s.Metallic);
            Unity_GlossyEnvironmentData g = UnityGlossyEnvironmentSetup(s.Smoothness, data.worldViewDir, s.Normal, F0);
            gi = UnityGlobalIllumination(data, s.Occlusion, s.Normal, g);
        }

        struct Input
        {
            float2 customTiledUV;
            float3 viewDir;
            float3 lightDir;
            float vface : VFACE;
            float3 worldPos;
            float3 worldNormal;
            float3 worldTangent;
            float3 worldBinormal;
        };

        // Vertex Function
        void vert (inout appdata_full v, out Input o)
        {
            UNITY_SETUP_INSTANCE_ID(v);
            UNITY_INITIALIZE_OUTPUT(Input, o);
            o.customTiledUV = v.texcoord.xy * _MainTex_ST.xy + _MainTex_ST.zw;

            TANGENT_SPACE_ROTATION;
            o.viewDir = mul(rotation, ObjSpaceViewDir(v.vertex));
            o.lightDir = mul(rotation, ObjSpaceLightDir(v.vertex));
            o.worldPos = mul(unity_ObjectToWorld, v.vertex).xyz;
            
            o.worldNormal = UnityObjectToWorldNormal(v.normal);
            o.worldTangent = UnityObjectToWorldDir(v.tangent.xyz);
            o.worldBinormal = cross(o.worldNormal, o.worldTangent) * v.tangent.w;
        }

        // SSS approximation with view-dependent normal distortion.
        // This method is more robust on flat surfaces as it uses a thickness map
        // to create variation instead of relying solely on surface curvature.
        half3 CalculateSubsurfaceScattering(Input IN, half3 normal, half3 albedo, half thickness)
        {
            // --- Inputs ---
            half3 lightDir = normalize(IN.lightDir);
            half3 viewDir = normalize(IN.viewDir);

            // --- Forward Scattering (Light wrapping) ---
            // We distort the normal based on the view direction and thickness.
            // This simulates looking "into" the material, where light has scattered.
            // _SubsurfaceRadius controls how much the thickness distorts the normal.
            half3 distortedNormal = normalize(normal - viewDir * thickness * _SubsurfaceRadius);

            // Calculate the lighting with this new, distorted normal.
            half wrap = saturate(dot(distortedNormal, lightDir));

            // --- Back Scattering (Translucency) ---
            // This term simulates light passing directly through the object from behind.
            // It creates a "glowing" effect on the edges opposite the light source.
            half backscatter = saturate(dot(viewDir, -lightDir));
            // _ScatterDistance controls the tightness of the glow.
            backscatter = pow(backscatter, _ScatterDistance * 5.0h);

            // --- Combine and Modulate ---
            // We combine the forward and back scattering terms.
            half sss = (wrap + backscatter) * 0.5h; // Average the two effects

            // Modulate the result by the subsurface color, albedo, thickness, and overall intensity.
            // Multiplying by thickness makes the effect more pronounced in thicker areas.
            half3 finalSSS = sss * thickness * _SubsurfaceColor.rgb * albedo;
            finalSSS *= _SubsurfaceIntensity;

            return finalSSS;
        }

        // Reoriented Normal Mapping helper
        half3 Ymne_BlendNormals(half3 baseNormal, half3 detailNormal)
        {
            baseNormal += half3(0, 0, 1);
            detailNormal *= half3(-1, -1, 1);
            return baseNormal * dot(baseNormal, detailNormal) / baseNormal.z - detailNormal;
        }
        
        // Surface Function
        void surf (Input IN, inout SurfaceOutputCustom o)
        {
            float2 uv = IN.customTiledUV;
            half shadow = 1.0;

            #if defined(_USEPOM_ON)
            // Parallax Occlusion Mapping
            float3 viewDir = normalize(IN.viewDir);
            float stepSize = 1.0 / _POMSamples;
            float2 uvStep = - ((viewDir.xy * _Parallax) * stepSize);

            float2 currentUV = IN.customTiledUV;
            float currentHeight = 1.0;

            float2 ddx_uv = ddx(IN.customTiledUV);
            float2 ddy_uv = ddy(IN.customTiledUV);

            // Raymarching
            [loop]
            for (int i = 0; i < _POMSamples; i ++)
            {
                currentHeight -= stepSize;
                currentUV += uvStep;
                float sampledHeight = tex2Dgrad(_ParallaxMap, currentUV, ddx_uv, ddy_uv).r;
                if (sampledHeight > currentHeight)
                {
                    // Refinement Step
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

            // POM Self-Shadowing with Softness
            float3 lightDir = normalize(IN.lightDir);
            float shadowStep = 1.0 / _POMShadowSamples;
            float2 shadowUVStep = ((lightDir.xy * _Parallax * _POMShadowDistance) * shadowStep);

            float2 shadowUV = uv;
            float shadowHeight = currentHeight;
            float totalShadow = 0.0;
            int shadowsFound = 0;

            [loop]
            for (int j = 1; j < (int)_POMShadowSamples; j++)
            {
                shadowHeight += shadowStep;
                shadowUV += shadowUVStep;
                float sampledHeight = tex2Dgrad(_ParallaxMap, shadowUV, ddx_uv, ddy_uv).r;
                if (sampledHeight > shadowHeight + _POMShadowThreshold)
                {
                    float penumbra = saturate((sampledHeight - shadowHeight) / (_POMShadowSoftness + 0.0001));
                    totalShadow += penumbra;
                    shadowsFound++;
                }
            }
            
            if (shadowsFound > 0)
            {
                shadow = 1.0 - saturate((totalShadow / shadowsFound) * _POMShadowIntensity);
            }
            #endif

            // Albedo & Alpha
            fixed4 c = tex2D(_MainTex, uv) * _Color;
            half alpha = c.a;

            #if defined(_CUTOUT_ON)
            clip(alpha - _Cutoff);
            #endif

            o.Albedo = c.rgb;

            // Normal Mapping
            half3 normal = UnpackScaleNormal(tex2D(_NormalMap, uv), _BumpScale);

            // Detail Mapping
            float2 detailUV = uv * _DetailMapTiling;
            half3 detailAlbedo = tex2D(_DetailAlbedoMap, detailUV).rgb;
            o.Albedo = lerp(o.Albedo, o.Albedo * detailAlbedo * 2, _DetailAlbedoIntensity);
            half3 detailNormal = UnpackScaleNormal(tex2D(_DetailNormalMap, detailUV), _DetailNormalScale);
            normal = Ymne_BlendNormals(normal, detailNormal);
            
            o.Normal = normalize(normal);
            
            // Tangent Space for Anisotropy
            o.Tangent = IN.worldTangent;
            o.Binormal = IN.worldBinormal;

            // PBR Properties
            float roughnessMapValue = tex2D(_RoughnessMap, uv).r;
            //Stylistic adjustment: roughness is multiplied by 2.5 to make materials appear more matte/diffuse
            float roughnessValue = roughnessMapValue * (_Roughness * 2.5);
            o.Metallic = tex2D(_MetallicMap, uv).r * _Metallic;
            o.Smoothness = (1.0 - roughnessValue) * _SpecularIntensity;
            o.Occlusion = lerp(1, tex2D(_OcclusionMap, uv).g, _OcclusionStrength);
            o.WorldPos = IN.worldPos;
            o.DirectShadow = shadow;
            o.UV = uv;

            // Clear Coat Properties
            o.ClearCoat = tex2D(_ClearCoatMask, uv).r * _ClearCoat;
            o.ClearCoatRoughness = _ClearCoatRoughness;

            // Emission & SSS
            o.Emission = tex2D(_EmissionMap, uv).rgb * _EmissionColor.rgb * _EmissionIntensity;
            
            #if defined(_USESS_ON)
            half2 sssData = tex2D(_SubsurfaceDataMap, uv).rg;
            half sssMask = sssData.r;
            half thickness = sssData.g * _ThicknessScale;
            half3 subsurface = CalculateSubsurfaceScattering(IN, o.Normal, o.Albedo, thickness);
            o.Albedo *= (1.0 - sssMask * _SubsurfaceColor.a * 0.5); // Energy Conservation
            o.Emission += subsurface * sssMask;
            #endif

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
                                backUV = midUV;
                                backRayHeight = midRayHeight;
                            } else {
                                frontUV = midUV;
                                frontRayHeight = midRayHeight;
                            }
                        }
                        currentUV = (frontUV + backUV) * 0.5;
                        break;
                    }
                }
                uv = currentUV;
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
