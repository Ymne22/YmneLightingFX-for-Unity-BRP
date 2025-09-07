Shader "Hidden/SSR"
{
    Properties
    {
        _MainTex("Texture", 2D) = "white" {}
    }
    SubShader
    {
        Cull Off ZWrite Off ZTest Always

        CGINCLUDE
        #include "UnityCG.cginc"

        #define PI 3.14159265359

        struct appdata {
            float4 vertex : POSITION;
            float2 uv : TEXCOORD0;
        };

        struct v2f {
            float2 uv : TEXCOORD0;
            float4 vertex : SV_POSITION;
            float3 ray : TEXCOORD1;
        };

        sampler2D _MainTex;
        sampler2D_float _CameraDepthTexture;
        sampler2D_float _CameraDepthNormalsTexture;
        float4x4 _InverseProjection, _Projection, _InverseView, _PrevViewProjMatrix;
        half _UseTemporalDithering;

        v2f vert(appdata v) {
            v2f o;
            o.vertex = UnityObjectToClipPos(v.vertex);
            o.uv = v.uv;
            // Calculate view-space ray from camera origin to far plane
            o.ray = mul(_InverseProjection, float4(v.uv * 2 - 1, 0, 1)).xyz;
            return o;
        }
        
        // Generates a quasi-random sequence for stratified sampling
        float2 Halton(int index, int b1, int b2) {
            half r1 = 0.0, f1 = 1.0;
            int i = index;
            while (i > 0) { f1 /= b1; r1 += f1 * (i % b1); i = floor(i / (half)b1); }
            half r2 = 0.0, f2 = 1.0;
            i = index;
            while (i > 0) { f2 /= b2; r2 += f2 * (i % b2); i = floor(i / (half)b2); }
            return float2(r1, r2);
        }

        // Reads and linearizes depth from the depth texture
        half readDepth(float2 coord) {
            return LinearEyeDepth(SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, coord));
        }

        // Reconstructs view-space position and normal from G-Buffers
        void getSceneData(float2 uv, float3 ray, out float3 viewPos, out float3 viewNormal) {
            half depth = readDepth(uv);
            viewPos = ray * depth; 
            half rawDepth;
            DecodeDepthNormal(tex2D(_CameraDepthNormalsTexture, uv), rawDepth, viewNormal);
        }
        
        // Creates a basis (tangent and bitangent) from a normal vector
        void getBasis(float3 n, out float3 t, out float3 b) {
            float3 up = abs(n.z) < 0.999 ? float3(0, 0, 1) : float3(1, 0, 0);
            t = normalize(cross(up, n));
            b = cross(n, t);
        }
        ENDCG

        // PASS 0: SSR-Only Ray-Marching
        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag_ssr

            int _SampleCount;
            half _MaxRayDistance, _IntersectionThickness, _SampleClampValue;
            half _MinSmoothness, _MinMetallic;
            sampler2D _CameraGBufferTexture1; // Specular color (RGB) and Smoothness (A)
            sampler2D _CameraGBufferTexture3; // Emission and lighting

            float4 frag_ssr(v2f i, float4 screenPos : SV_Position) : SV_Target
            {
                // Ignore skybox pixels
                if (readDepth(i.uv) >= 0.999 * _ProjectionParams.z) return 0;
                
                float3 viewPos, viewNormal;
                getSceneData(i.uv, i.ray, viewPos, viewNormal);
                
                half4 gbuffer1 = tex2D(_CameraGBufferTexture1, i.uv);
                half3 specularColor = gbuffer1.rgb;
                half smoothness = gbuffer1.a;
                half metallic = specularColor.r; // In Unity's metallic workflow, this is a good approximation

                // **NEW:** Threshold check
                if (smoothness < _MinSmoothness && metallic < _MinMetallic) {
                    return 0;
                }

                half roughness = 1.0h - smoothness;

                float3 viewDir = normalize(viewPos);
                float3 reflectDir = reflect(viewDir, viewNormal);

                float3 totalReflection = 0;
                float3 origin = viewPos + viewNormal * (length(viewPos) * 0.005);
                
                half randomRotation;
                if (_UseTemporalDithering > 0.5h)
                {
                    float frameIndex = fmod(_Time.y * 60.0, 8.0);
                    float2 jitter = float2(frameIndex * 0.125, frameIndex * 0.125);
                    float dither = frac(52.9829189 * frac(0.06711056 * (screenPos.x + jitter.x) + 0.00583715 * (screenPos.y + jitter.y)));
                    randomRotation = dither * 2.0 * PI;
                }
                else
                {
                    float2 p = frac(screenPos.xy * float2(0.1031, 0.1030));
                    p += dot(p, p.yx + 19.19);
                    float static_hash = frac((p.x + p.y) * p.y);
                    randomRotation = static_hash * 2.0 * PI;
                }

                float3 t, b;
                getBasis(reflectDir, t, b);

                [loop]
                for (int j = 0; j < _SampleCount; j++)
                {
                    float2 xi = Halton(j, 2, 3);
                    half phi = 2.0 * PI * xi.x + randomRotation;
                    half cosTheta = sqrt(1.0 - xi.y);
                    half sinTheta = sqrt(1.0 - cosTheta * cosTheta);
                    float3 localDir = float3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);
                    
                    float3 jitteredDir = localDir.x * t + localDir.y * b + localDir.z * reflectDir;
                    
                    float3 viewspaceRayDir = normalize(lerp(reflectDir, jitteredDir, pow(roughness, 0.5h)));

                    half random_len_frac = frac(randomRotation + j * 0.379);
                    half ray_max_dist = lerp(0.1, _MaxRayDistance, random_len_frac);
                    
                    const int marchSteps = 16;
                    const half stepGrowth = 1.5;
                    half currentRayLen = 0.1 * (1.0 + random_len_frac);

                    for (int k = 0; k < marchSteps; k++) 
                    {
                        if (currentRayLen > ray_max_dist) break;

                        float3 currentRayPos = origin + viewspaceRayDir * currentRayLen;
                        float4 currentClip = mul(_Projection, float4(currentRayPos, 1.0));
                        float2 currentUV = (currentClip.xy / currentClip.w) * 0.5 + 0.5;

                        if (saturate(currentUV).x != currentUV.x || saturate(currentUV).y != currentUV.y) break;
                        
                        half sceneDepth = readDepth(currentUV);
                        half rayDepth = -currentRayPos.z;
                        half dynamicThickness = _IntersectionThickness * saturate(sceneDepth * 0.1);

                        if (rayDepth > sceneDepth && (rayDepth - sceneDepth) < dynamicThickness) 
                        {
                            if (sceneDepth < 0.999 * _ProjectionParams.z)
                            {
                                half3 reflectedColor = tex2D(_CameraGBufferTexture3, half4(currentUV, 0, 0)).rgb;
                                
                                float2 screenEdge = abs(currentUV - 0.5) * 2.0;
                                float fade = 1.0 - saturate(pow(max(screenEdge.x, screenEdge.y), 6.0));

                                totalReflection += min(reflectedColor, (half3)_SampleClampValue) * fade;
                            }
                            break;
                        }
                        currentRayLen *= stepGrowth;
                    }
                }

                if(_SampleCount > 0) totalReflection /= (half)_SampleCount;

                return float4(totalReflection, 1.0);
            }
            ENDCG
        }

        // PASS 1: Composite
        Pass
        {
            CGPROGRAM
            #pragma vertex vert_fullres
            #pragma fragment frag_composite

            struct v2f_fullres { float4 vertex : SV_POSITION; float2 uv : TEXCOORD0; };
            v2f_fullres vert_fullres(appdata_base v) { v2f_fullres o; o.vertex = UnityObjectToClipPos(v.vertex); o.uv = v.texcoord; return o; }
            
            sampler2D _AccumulatedSSRTex, _CameraGBufferTexture0, _CameraGBufferTexture1;
            half _ReflectionIntensity;
            
            float4 frag_composite(v2f_fullres i) : SV_Target
            {
                float4 originalColor = tex2D(_MainTex, i.uv);
                float3 reflection = tex2D(_AccumulatedSSRTex, i.uv).rgb;
                
                half4 gbuffer1 = tex2D(_CameraGBufferTexture1, i.uv);
                half3 specularColor = gbuffer1.rgb; 
                half smoothness = gbuffer1.a;
                
                float3 viewNormal;
                half rawDepth;
                DecodeDepthNormal(tex2D(_CameraDepthNormalsTexture, i.uv), rawDepth, viewNormal);
                float3 viewRay = mul(_InverseProjection, float4(i.uv * 8, 0, 1)).xyz;
                float3 viewPos = viewRay * LinearEyeDepth(rawDepth);
                float3 viewDir = normalize(viewPos);

                half fresnelTerm = pow(1.25 - saturate(dot(viewNormal, -viewDir)), 5.0);
                half3 F = specularColor + (max(smoothness, specularColor.r) - specularColor) * fresnelTerm;
                
                float3 finalReflection = reflection * F * _ReflectionIntensity;
                
                float3 finalColor = originalColor.rgb + finalReflection;
                
                return float4(finalColor, originalColor.a);
            }
            ENDCG
        }

        // PASS 2: Denoiser
        Pass
        {
            CGPROGRAM
            #pragma vertex vert_fullres
            #pragma fragment frag_gaussian_blur

            struct v2f_fullres { float4 vertex : SV_POSITION; half2 uv : TEXCOORD0; };
            v2f_fullres vert_fullres(appdata_base v) { v2f_fullres o; o.vertex = UnityObjectToClipPos(v.vertex); o.uv = v.texcoord; return o; }

            sampler2D _BlurSourceTex;
            half4 _FullResTexelSize;
            half _BlurRadius, _BlurDepthWeight, _BlurNormalWeight;

            half4 frag_gaussian_blur(v2f_fullres i) : SV_Target
            {
                half centerDepth = readDepth(i.uv);
                half rawDepth;
                half3 centerNormal;
                DecodeDepthNormal(tex2D(_CameraDepthNormalsTexture, i.uv), rawDepth, centerNormal);

                half4 total = 0.0h;
                half totalWeight = 0.0h;

                [unroll]
                for (int x = -1; x <= 2; x++) {
                    [unroll]
                    for (int y = -2; y <= 1; y++) {
                        half2 offset = half2(x, y) * _FullResTexelSize.xy * _BlurRadius * 2;
                        half2 sampleUV = i.uv + offset;

                        half sampleDepth = readDepth(sampleUV);
                        half3 sampleNormal;
                        DecodeDepthNormal(tex2D(_CameraDepthNormalsTexture, sampleUV), rawDepth, sampleNormal);

                        half depthDiff = abs(centerDepth - sampleDepth);
                        half depthW = exp(-_BlurDepthWeight * depthDiff * depthDiff);
                        half normalDot = saturate(dot(centerNormal, sampleNormal));
                        half normalW = pow(normalDot, 4);
                        half dist = dot(offset, offset);
                        half gaussW = exp(-dist * 2.0);

                        half weight = gaussW * depthW * normalW;
                        total += tex2D(_BlurSourceTex, sampleUV) * weight;
                        totalWeight += weight;
                    }
                }
                
                if (totalWeight > 1e-4) {
                    return float4(total.rgb / totalWeight, 1.0);
                } else {
                    return tex2D(_BlurSourceTex, i.uv);
                }
            }
            ENDCG
        }

        // PASS 3: Temporal Reprojection
        Pass
        {
            CGPROGRAM
            #pragma vertex vert_fullres
            #pragma fragment frag_temporal

            struct v2f_fullres { float4 vertex : SV_POSITION; half2 uv : TEXCOORD0; };
            v2f_fullres vert_fullres(appdata_base v) { v2f_fullres o; o.vertex = UnityObjectToClipPos(v.vertex); o.uv = v.texcoord; return o; }

            sampler2D _CurrentFrameTex, _HistoryTex;
            half _TemporalBlendFactor;

            float4 frag_temporal(v2f_fullres i) : SV_Target
            {
                float4 current = tex2D(_CurrentFrameTex, i.uv);
                
                float depth = readDepth(i.uv);
                float3 viewRay = mul(_InverseProjection, float4(i.uv * 2 - 1, 0, 1)).xyz;
                float3 viewPos = viewRay * depth;
                float4 worldPos = mul(_InverseView, float4(viewPos, 1.0));
                
                float4 prevClipPos = mul(_PrevViewProjMatrix, worldPos);
                float2 prevUV = (prevClipPos.xy / prevClipPos.w) * 0.5 + 0.5;

                if (saturate(prevUV).x == prevUV.x && saturate(prevUV).y == prevUV.y)
                {
                    float4 history = tex2D(_HistoryTex, prevUV);
                    
                    float4 center = tex2D(_CurrentFrameTex, i.uv);
                    float4 min_val = center;
                    float4 max_val = center;

                    [unroll]
                    for (int x = -1; x <= 1; x++) {
                        for (int y = -1; y <= 1; y++) {
                            float2 offset = float2(x, y) * _ScreenParams.zw;
                            float4 s = tex2D(_CurrentFrameTex, i.uv + offset);
                            min_val = min(min_val, s);
                            max_val = max(max_val, s);
                        }
                    }
                    history = clamp(history, min_val, max_val);
                    return lerp(current, history, _TemporalBlendFactor);
                }
                return current;
            }
            ENDCG
        }
        
        // PASS 4: Copy
        Pass
        {
            CGPROGRAM
            #pragma vertex vert_fullres
            #pragma fragment frag_copy

            struct v2f_fullres { float4 vertex : SV_POSITION; float2 uv : TEXCOORD0; };
            v2f_fullres vert_fullres(appdata_base v) { v2f_fullres o; o.vertex = UnityObjectToClipPos(v.vertex); o.uv = v.texcoord; return o; }

            float4 frag_copy(v2f_fullres i) : SV_Target { return tex2D(_MainTex, i.uv); }
            ENDCG
        }
    }
}
