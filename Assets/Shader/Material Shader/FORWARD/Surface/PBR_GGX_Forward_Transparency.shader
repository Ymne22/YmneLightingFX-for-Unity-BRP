Shader "YmneShader/PBR_GGX_Forward_Transparent (Experimental)"
{
    Properties
    {
        // --- Rendering and Opacity ---
        [Header(Rendering and Opacity)]
        [Enum(UnityEngine.Rendering.BlendMode)] _SrcBlend ("Source Blend", Float) = 5 // Source Alpha
        [Enum(UnityEngine.Rendering.BlendMode)] _DstBlend ("Destination Blend", Float) = 10 // One Minus Source Alpha
        [Enum(Off, 0, Front, 1, Back, 2)] _Culling ("Culling", Float) = 2.0
        [Toggle(_CUTOUT_ON)] _UseCutout ("Enable Alpha Cutout", Float) = 0.0
        _Cutoff ("Alpha Cutoff", Range(0.0, 1.0)) = 0.5

        // --- Refraction ---
        [Header(Refraction)]
        _RefractionStrength("Refraction Strength", Range(0.0, 1.0)) = 0.05
        _RefractionDispersion("Chromatic Aberration", Range(0.0, 0.1)) = 0.01

        // --- Primary Surface Maps ---
        [Space(10)] [Header(Primary Surface Maps)]
        _Color ("Color", Color) = (1, 1, 1, 0.5)
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

        // --- Detail Mapping (2nd Layer) ---
        [Space(10)] [Header(Detail Mapping)]
        _DetailAlbedoMap ("Detail Albedo (RGB) & Alpha (A)", 2D) = "gray" {}
        _DetailAlbedoIntensity("Detail Opacity", Range(0,1)) = 1.0
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
    }
    SubShader
    {
        Tags { "RenderType"="Transparent" "Queue"="Transparent" "IgnoreProjector"="True" }
        LOD 200

        // RE-ADDED: GrabPass is needed for refraction.
        GrabPass { "_GrabTexture" }

        Blend [_SrcBlend] [_DstBlend]
        ZWrite Off
        Cull [_Culling]

        CGPROGRAM
        #pragma surface surf CustomPBR fullforwardshadows addshadow vertex:vert alpha:fade
        #pragma target 5.0
        #pragma multi_compile_instancing

        #pragma multi_compile __ _CUTOUT_ON
        // Removed POM and SSS shader features

        #include "UnityPBSLighting.cginc"

        // RE-ADDED: Refraction variables are needed again.
        sampler2D _GrabTexture;
        half _RefractionStrength;
        half _RefractionDispersion;

        sampler2D _MainTex, _NormalMap, _MetallicMap, _RoughnessMap, _OcclusionMap,
        _EmissionMap, _DetailAlbedoMap, _DetailNormalMap, _ClearCoatMask;
        float4 _MainTex_ST;

        float _Culling;
        half _Roughness, _Metallic, _BumpScale, _OcclusionStrength,
        _Cutoff, _SpecularIntensity;
        half _EmissionIntensity;
        half _ToksvigStrength;
        half _DetailMapTiling, _DetailNormalScale, _DetailAlbedoIntensity;
        half _Anisotropy;
        half _ClearCoat, _ClearCoatRoughness;
        half _RimPower, _RimIntensity;
        fixed4 _Color, _EmissionColor, _DielectricF0, _RimColor;
        
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
        
        float D_GGX_Aniso(float NdotH, float HdotT, float HdotB, float ax, float ay) {
            float HdotT2 = HdotT * HdotT;
            float HdotB2 = HdotB * HdotB;
            float NdotH2 = NdotH * NdotH;
            float den_term = (HdotT2 / (ax * ax)) + (HdotB2 / (ay * ay)) + NdotH2;
            return 1.0 / (UNITY_PI * ax * ay * den_term * den_term);
        }

        inline half D_GGX(half NdotH, half roughness) {
            half a = roughness * roughness;
            half a2 = a * a;
            half NdotH2 = NdotH * NdotH;
            half d = (NdotH2 * (a2 - 1.0) + 1.0);
            return a2 / (UNITY_PI * d * d);
        }

        inline half G_SchlickGGX(half NdotV, half roughness) {
            half r = roughness + 1.0;
            half k = (r * r) / 8.0;
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
            half lightScatter = (1.0 + (Fd90 - 1.0) * pow(1.0 - NdotL, 1.0));
            half viewScatter = (1.0 + (Fd90 - 1.0) * pow(1.0 - NdotV, 1.0));
            return lightScatter * viewScatter;
        }

        half4 LightingCustomPBR(SurfaceOutputCustom s, half3 viewDir, UnityGI gi) {
            half3 N = s.Normal;
            half3 V = viewDir;
            half roughness = 1.0 - s.Smoothness;
            float2 duv_dx = ddx(s.UV);
            float2 duv_dy = ddy(s.UV);
            half3 dN_dx = UnpackScaleNormal(tex2Dgrad(_NormalMap, s.UV, duv_dx, duv_dy), _BumpScale) - N;
            half3 dN_dy = UnpackScaleNormal(tex2Dgrad(_NormalMap, s.UV, duv_dx, duv_dy), _BumpScale) - N;
            half variance = dot(dN_dx, dN_dx) + dot(dN_dy, dN_dy);
            roughness = saturate(roughness + variance * _ToksvigStrength);
            roughness = max(roughness, 0.001h);
            half3 albedo = s.Albedo;
            half metallic = s.Metallic;
            half3 L = gi.light.dir;
            half3 H = normalize(V + L);
            half NdotL = saturate(dot(N, L));
            half NdotV = abs(dot(N, V));
            half NdotH = saturate(dot(N, H));
            half LdotH = saturate(dot(L, H));
            half VdotH = saturate(dot(V, H));
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
            half3 kS = F;
            half3 kD = (half3(1.0, 1.0, 1.0) - kS) * (1.0 - metallic);
            half disneyDiffuse = Fd_Disney(NdotV, NdotL, LdotH, roughness);
            half3 diffuse = disneyDiffuse * kD * albedo / UNITY_PI;
            diffuse *= s.Occlusion;
            half3 directColor = (diffuse + specular) * gi.light.color * NdotL * s.DirectShadow;
            half3 kS_indirect = F_Schlick(NdotV, lerp(F0_dielectric_val, albedo, metallic));
            half3 kD_indirect = (1.0 - kS_indirect) * (1.0 - metallic);
            half3 indirectDiffuse = gi.indirect.diffuse * albedo * kD_indirect;
            half3 reflection = gi.indirect.specular;
            half3 indirectSpecular = reflection * kS_indirect;
            half3 finalColor = directColor + indirectDiffuse + indirectSpecular;
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
            half rim = 1.0 - saturate(dot(N, V));
            rim = pow(rim, _RimPower);
            finalColor += _RimColor.rgb * rim * _RimIntensity * gi.light.color * NdotL;
            finalColor += s.Emission;
            return half4(finalColor, s.Alpha);
        }
        
        void LightingCustomPBR_GI(SurfaceOutputCustom s, UnityGIInput data, inout UnityGI gi) {
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
            // RE-ADDED: screenPos is needed for refraction
            float4 screenPos;
            UNITY_VERTEX_INPUT_INSTANCE_ID
            UNITY_VERTEX_OUTPUT_STEREO
            float3 worldNormal;
            float3 worldTangent;
            float3 worldBinormal;
            INTERNAL_DATA
        };

        void vert (inout appdata_full v, out Input o) {
            UNITY_SETUP_INSTANCE_ID(v);
            UNITY_INITIALIZE_OUTPUT(Input, o);
            UNITY_TRANSFER_INSTANCE_ID(v, o);
            UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
            
            o.customTiledUV = v.texcoord.xy * _MainTex_ST.xy + _MainTex_ST.zw;
            // RE-ADDED: screenPos calculation is needed for refraction
            o.screenPos = ComputeGrabScreenPos(UnityObjectToClipPos(v.vertex));
            o.worldPos = mul(unity_ObjectToWorld, v.vertex).xyz;
            o.worldNormal = UnityObjectToWorldNormal(v.normal);
            o.viewDir = _WorldSpaceCameraPos.xyz - o.worldPos;
            o.lightDir = _WorldSpaceLightPos0.xyz;

            o.worldTangent = UnityObjectToWorldDir(v.tangent.xyz);
            o.worldBinormal = cross(o.worldNormal, o.worldTangent) * v.tangent.w;
        }
        
        half3 Ymne_BlendNormals(half3 baseNormal, half3 detailNormal) {
            baseNormal += half3(0, 0, 1);
            detailNormal *= half3(-1, -1, 1);
            return baseNormal * dot(baseNormal, detailNormal) / baseNormal.z - detailNormal;
        }
        
        void surf (Input IN, inout SurfaceOutputCustom o)
        {
            UNITY_SETUP_INSTANCE_ID(IN);
            float2 uv = IN.customTiledUV;
            half shadow = 1.0;

            fixed4 c = tex2D(_MainTex, uv) * _Color;
            half alpha = c.a;

            #if defined(_CUTOUT_ON)
            clip(alpha - _Cutoff);
            #endif

            fixed3 surfaceAlbedo = c.rgb;
            
            // --- DETAIL MAPPING (2nd Layer) ---
            float2 detailUV = uv * _DetailMapTiling;
            fixed4 detailTex = tex2D(_DetailAlbedoMap, detailUV);
            // Blend the detail texture over the base albedo using its alpha
            surfaceAlbedo = lerp(surfaceAlbedo, detailTex.rgb, detailTex.a * _DetailAlbedoIntensity);

            half3 tangentNormal = UnpackScaleNormal(tex2D(_NormalMap, uv), _BumpScale);
            half3 detailNormal = UnpackScaleNormal(tex2D(_DetailNormalMap, detailUV), _DetailNormalScale);
            tangentNormal = Ymne_BlendNormals(tangentNormal, detailNormal);
            o.Normal = normalize(tangentNormal);
            
            o.Emission = tex2D(_EmissionMap, uv).rgb * _EmissionColor.rgb * _EmissionIntensity;

            // --- REFRACTION ---
            half3 worldNormal = WorldNormalVector(IN, o.Normal);
            half3 viewNormal = mul((float3x3)UNITY_MATRIX_V, worldNormal);
            float2 screenUV = IN.screenPos.xy / IN.screenPos.w;
            
            half2 offset = viewNormal.xy * _RefractionStrength;

            fixed3 refraction;
            refraction.r = tex2D(_GrabTexture, screenUV + offset * (1.0 - _RefractionDispersion)).r;
            refraction.g = tex2D(_GrabTexture, screenUV + offset).g;
            refraction.b = tex2D(_GrabTexture, screenUV + offset * (1.0 + _RefractionDispersion)).b;

            // MODIFIED: Blend the refraction with the surface albedo based on the material's alpha.
            o.Albedo = lerp((refraction * 10), surfaceAlbedo, alpha);

            o.WorldPos = IN.worldPos;
            o.Tangent = IN.worldTangent;
            o.Binormal = IN.worldBinormal;

            float roughnessMapValue = tex2D(_RoughnessMap, uv).r;
            float roughnessValue = roughnessMapValue * (_Roughness * 2.5);
            o.Metallic = tex2D(_MetallicMap, uv).r * _Metallic;
            o.Smoothness = (1.0 - roughnessValue) * _SpecularIntensity;
            o.Occlusion = lerp(1, tex2D(_OcclusionMap, uv).g, _OcclusionStrength);
            o.DirectShadow = shadow;
            o.UV = uv;
            o.ClearCoat = tex2D(_ClearCoatMask, uv).r * _ClearCoat;
            o.ClearCoatRoughness = _ClearCoatRoughness;
            
            // MODIFIED: Set the final alpha from the texture/color alpha for standard blending.
            o.Alpha = alpha;
        }
        ENDCG

        // Shadow Caster & Meta passes (unchanged)
        Pass { Name "ShadowCaster" Tags { "LightMode" = "ShadowCaster" } ZWrite On ZTest LEqual Cull [_Culling] CGPROGRAM #pragma vertex vert_shadow #pragma fragment frag_shadow #pragma multi_compile_shadowcaster #pragma shader_feature _CUTOUT_ON #include "UnityCG.cginc" struct v2f_shadow { V2F_SHADOW_CASTER; float2 uv : TEXCOORD1; float3 viewDir : TEXCOORD2; }; sampler2D _MainTex; float4 _MainTex_ST; fixed4 _Color; half _Cutoff; v2f_shadow vert_shadow(appdata_full v) { v2f_shadow o; UNITY_INITIALIZE_OUTPUT(v2f_shadow, o); TRANSFER_SHADOW_CASTER_NORMALOFFSET(o) o.uv = v.texcoord.xy * _MainTex_ST.xy + _MainTex_ST.zw; TANGENT_SPACE_ROTATION; o.viewDir = mul(rotation, ObjSpaceViewDir(v.vertex)); return o; } fixed4 frag_shadow(v2f_shadow i) : SV_Target { float2 uv = i.uv; fixed4 tex = tex2D(_MainTex, uv) * _Color; half alpha = tex.a; #if defined(_CUTOUT_ON) clip(alpha - _Cutoff); #endif SHADOW_CASTER_FRAGMENT(i) } ENDCG }
        Pass { Name "Meta" Tags { "LightMode" = "Meta" } Cull Off CGPROGRAM #pragma vertex vert_meta #pragma fragment frag_meta #pragma shader_feature _CUTOUT_ON #include "UnityCG.cginc" #include "UnityMetaPass.cginc" sampler2D _MainTex, _EmissionMap, _NormalMap; float4 _MainTex_ST; fixed4 _Color, _EmissionColor; half _EmissionIntensity, _Cutoff; float _BumpScale; struct v2f_meta { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; float3 TtoW0 : TEXCOORD1; float3 TtoW1 : TEXCOORD2; float3 TtoW2 : TEXCOORD3; }; v2f_meta vert_meta(appdata_full v) { v2f_meta o; o.pos = UnityMetaVertexPosition(v.vertex, v.texcoord1.xy, v.texcoord2.xy, unity_LightmapST, unity_DynamicLightmapST); o.uv = v.texcoord.xy * _MainTex_ST.xy + _MainTex_ST.zw; float3 worldPos = mul(unity_ObjectToWorld, v.vertex).xyz; float3 worldNormal = UnityObjectToWorldNormal(v.normal); float3 worldTangent = UnityObjectToWorldDir(v.tangent.xyz); float3 worldBinormal = cross(worldNormal, worldTangent) * v.tangent.w; o.TtoW0 = float3(worldTangent.x, worldBinormal.x, worldNormal.x); o.TtoW1 = float3(worldTangent.y, worldBinormal.y, worldNormal.y); o.TtoW2 = float3(worldTangent.z, worldBinormal.z, worldNormal.z); return o; } inline half3 UnpackNormal_Meta(half4 packednormal) { #if defined(UNITY_NO_DXT5nm) return packednormal.xyz * 2 - 1; #else half3 normal; normal.xy = packednormal.wy * 2 - 1; normal.z = sqrt(1.0 - saturate(dot(normal.xy, normal.xy))); return normal; #endif } inline half3 UnpackScaleNormal_Meta(half4 packednormal, half bumpScale) { half3 normal = UnpackNormal_Meta(packednormal); normal.xy *= bumpScale; normal.z = sqrt(1.0 - saturate(dot(normal.xy, normal.xy))); return normal; } struct frag_meta_out { half4 Albedo : SV_Target0; half4 Normal : SV_Target1; }; frag_meta_out frag_meta(v2f_meta i) { UnityMetaInput metaIN; UNITY_INITIALIZE_OUTPUT(UnityMetaInput, metaIN); fixed4 albedo = tex2D(_MainTex, i.uv) * _Color; #if defined(_CUTOUT_ON) half alpha = albedo.a; clip(alpha - _Cutoff); #endif metaIN.Albedo = albedo.rgb; metaIN.Emission = tex2D(_EmissionMap, i.uv).rgb * _EmissionColor.rgb * _EmissionIntensity; half3 tangentNormal = UnpackScaleNormal_Meta(tex2D(_NormalMap, i.uv), _BumpScale); half3 worldNormal = half3(dot(i.TtoW0, tangentNormal), dot(i.TtoW1, tangentNormal), dot(i.TtoW2, tangentNormal)); worldNormal = normalize(worldNormal); frag_meta_out o; o.Albedo = UnityMetaFragment(metaIN); o.Normal = half4(worldNormal * 0.5 + 0.5, 1); return o; } ENDCG }
    }
    FallBack "Transparent/VertexLit"
    CustomEditor "ShaderForgeMaterialInspector"
}
