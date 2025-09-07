Shader "Hidden/LightingStack"
{
    Properties { _MainTex("Texture", 2D) = "white" {} }

    SubShader
    {
        Cull Off ZWrite Off ZTest Always

        CGINCLUDE
        #include "UnityCG.cginc"
        #include "AutoLight.cginc"
        

        #define PI 3.14159265359

        struct appdata { float4 vertex : POSITION; float2 uv : TEXCOORD0; };
        struct v2f { float4 vertex : SV_POSITION; float2 uv : TEXCOORD0; float3 ray : TEXCOORD1;};

        sampler2D _MainTex, _EffectTex;
        sampler2D_float _CameraDepthTexture;
        sampler2D_float _CameraDepthNormalsTexture;
        sampler2D _CameraGBufferTexture0, _CameraGBufferTexture1, _CameraGBufferTexture3;
        sampler2D _CurrentFrameTex, _HistoryTex;

        float4x4 _InverseProjection, _Projection, _InverseView, _PrevViewProjMatrix;
        half _UseTemporalDithering;
        half4 _FullResTexelSize;
        half _TemporalBlendFactor;

        // SSGI
        int _SSGI_SampleCount;
        half _SSGI_MaxRayDistance, _SSGI_IntersectionThickness, _SSGI_Intensity, _SSGI_SampleClampValue;
        half _SSGI_CosineWeightedSampling;

        // SSAO
        int _SSAO_SampleCount;
        half _SSAO_Radius, _SSAO_Intensity, _SSAO_Power;

        // SSR
        int _SSR_SampleCount;
        half _SSR_MaxRayDistance, _SSR_IntersectionThickness, _SSR_Intensity, _SSR_SampleClampValue;
        half _SSR_MinSmoothness, _SSR_RoughnessContrast;

        // SSDCS
        int _SSDCS_SampleCount;
        half _SSDCS_MaxRayDistance, _SSDCS_Thickness, _SSDCS_Intensity;
        float3 _SSDCS_LightDirVS;
        
        v2f vert(appdata v)
        {
            v2f o;
            o.vertex = UnityObjectToClipPos(v.vertex);
            o.uv = v.uv;
            o.ray = mul(_InverseProjection, float4(v.uv * 2 - 1, 0, 1)).xyz;
            return o;
        }

        half readDepth(float2 coord) { return LinearEyeDepth(SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, coord)); }
        
        void getSceneData(float2 uv, float3 ray, out float3 viewPos, out float3 viewNormal)
        {
            half depth = readDepth(uv);
            viewPos = ray * depth;
            half rawDepth;
            DecodeDepthNormal(tex2D(_CameraDepthNormalsTexture, uv), rawDepth, viewNormal);
        }

        void getBasis(float3 n, out float3 t, out float3 b)
        {
            float3 up = abs(n.z) < 0.999 ? float3(0, 0, 1) : float3(1, 0, 0);
            t = normalize(cross(up, n));
            b = cross(n, t);
        }

        float2 Halton(int index, int b1, int b2)
        {
            half r1 = 0.0, f1 = 1.0; int i = index;
            while (i > 0) { f1 /= b1; r1 += f1 * (i % b1); i = floor(i / (half)b1); }
            half r2 = 0.0, f2 = 1.0; i = index;
            while (i > 0) { f2 /= b2; r2 += f2 * (i % b2); i = floor(i / (half)b2); }
            return float2(r1, r2);
        }
        
        half getRandomRotation(float4 screenPos)
        {
            if (_UseTemporalDithering > 0.5h)
            {
                float frameIndex = fmod(_Time.y * 60.0, 8.0);
                float2 jitter = float2(frameIndex * 0.125, frameIndex * 0.125);
                float dither = frac(52.9829189 * frac(0.06711056 * (screenPos.x + jitter.x) + 0.00583715 * (screenPos.y + jitter.y)));
                return dither * 2.0 * PI;
            }
            else
            {
                float2 p = frac(screenPos.xy * float2(0.1031, 0.1030));
                p += dot(p, p.yx + 19.19);
                return frac((p.x + p.y) * p.y) * 2.0 * PI;
            }
        }
        ENDCG

        // --- PASS 0: SSGI ---
        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag_ssgi
            half4 frag_ssgi(v2f i, float4 screenPos : SV_Position) : SV_Target
            {
                if (readDepth(i.uv) >= 0.999 * _ProjectionParams.z) return 0;
                float3 viewPos, viewNormal;
                getSceneData(i.uv, i.ray, viewPos, viewNormal);
                
                float3 t, b;
                getBasis(viewNormal, t, b);
                
                float3 totalIndirectLight = 0;
                float3 origin = viewPos + viewNormal * (viewPos.z * 0.001);
                half randomRotation = getRandomRotation(screenPos);

                [loop]
                for (int j = 0; j < _SSGI_SampleCount; j++)
                {
                    float2 xi = Halton(j, 2, 3);
                    half phi = 2.0 * PI * xi.x + randomRotation;
                    half cosTheta = lerp(xi.y, sqrt(xi.y), _SSGI_CosineWeightedSampling);
                    half sinTheta = sqrt(1.0 - cosTheta * cosTheta);
                    float3 localDir = float3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);
                    float3 viewspaceRayDir = localDir.x * t + localDir.y * b + localDir.z * viewNormal;

                    half random_len_frac = frac(randomRotation + j * 0.379);
                    half ray_max_dist = lerp(0.1, _SSGI_MaxRayDistance, random_len_frac);
                    const int marchSteps = 8;
                    const half stepGrowth = 1.8;
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
                        half dynamicThickness = _SSGI_IntersectionThickness * saturate(sceneDepth * 0.1);
                        
                        if (rayDepth > sceneDepth && (rayDepth - sceneDepth) < dynamicThickness && sceneDepth < 0.999 * _ProjectionParams.z) 
                        {
                            half3 finalColor = tex2D(_CameraGBufferTexture3, currentUV).rgb;
                            half3 albedo = tex2D(_CameraGBufferTexture0, currentUV).rgb;
                            half3 lightEnergy = finalColor / (albedo + 1e-4);
                            half3 indirectBounce = albedo * min(lightEnergy, (half3)_SSGI_SampleClampValue);
                            totalIndirectLight += (indirectBounce * 2) + (albedo * 0.015);
                            break;
                        }
                        currentRayLen *= stepGrowth;
                    }
                }
                if(_SSGI_SampleCount > 0) totalIndirectLight /= (half)_SSGI_SampleCount;
                return float4(totalIndirectLight, 1.0);
            }
            ENDCG
        }
        
        // --- PASS 1: SSAO ---
        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag_ssao
            half4 frag_ssao(v2f i, float4 screenPos : SV_Position) : SV_Target
            {
                if (readDepth(i.uv) >= 0.999 * _ProjectionParams.z) return 1.0f;
                float3 viewPos, viewNormal;
                getSceneData(i.uv, i.ray, viewPos, viewNormal);
                
                float3 t, b;
                getBasis(viewNormal, t, b);
                
                half occlusion = 0.0h;
                float3 origin = viewPos + viewNormal * 0.01h;
                half randomRotation = getRandomRotation(screenPos);
                
                const int numSteps = 4;
                [loop]
                for (int j = 0; j < _SSAO_SampleCount; j++)
                {
                    float2 xi = Halton(j, 2, 3);
                    half phi = 2.0 * PI * xi.x + randomRotation;
                    half cosTheta = sqrt(1.0 - xi.y);
                    half sinTheta = sqrt(xi.y);
                    float3 localDir = float3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);
                    float3 viewspaceRayDir = localDir.x * t + localDir.y * b + localDir.z * viewNormal;
                    
                    for (int step = 1; step <= numSteps; ++step)
                    {
                        float rayFrac = (float)step / numSteps;
                        float3 samplePos = origin + viewspaceRayDir * _SSAO_Radius * rayFrac * xi.x;
                        float4 projPos = mul(_Projection, float4(samplePos, 1.0));
                        float2 sampleUV = (projPos.xy / projPos.w) * 0.5 + 0.5;
                        if (saturate(sampleUV).x != sampleUV.x || saturate(sampleUV).y != sampleUV.y) continue;

                        half sceneDepth = readDepth(sampleUV);
                        half sampleDepth = -samplePos.z;
                        if (sampleDepth > sceneDepth)
                        {
                            half falloff = 1.0h - saturate((sampleDepth - sceneDepth) / _SSAO_Radius);
                            occlusion += pow(falloff, 2.0);
                            break;
                        }
                    }
                }

                if (_SSAO_SampleCount > 0) occlusion /= (half)_SSAO_SampleCount;
                occlusion = 1.0h - occlusion * _SSAO_Intensity;
                occlusion = pow(occlusion, _SSAO_Power);

                return occlusion;
            }
            ENDCG
        }

        // --- PASS 2: SSR ---
        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag_ssr
            float4 frag_ssr(v2f i, float4 screenPos : SV_Position) : SV_Target
            {
                if (readDepth(i.uv) >= 0.999 * _ProjectionParams.z) return 0;

                float3 viewPos, viewNormal;
                getSceneData(i.uv, i.ray, viewPos, viewNormal);
                
                half smoothness = tex2D(_CameraGBufferTexture1, i.uv).a;
                if (smoothness < _SSR_MinSmoothness) return 0;

                half roughness = 1.0h - smoothness;
                float3 viewDir = normalize(viewPos);
                float3 reflectDir = reflect(viewDir, viewNormal);

                float3 totalReflection = 0;
                float hitCount = 0.0h;

                float3 origin = viewPos + viewNormal * (length(viewPos) * 0.005);
                half randomRotation = getRandomRotation(screenPos);

                float3 t, b; getBasis(reflectDir, t, b);
                
                [loop]
                for (int j = 0; j < _SSR_SampleCount; j++)
                {
                    float2 xi = Halton(j, 2, 3);
                    half phi = 2.0 * PI * xi.x + randomRotation;
                    half cosTheta = sqrt(1.0 - xi.y);
                    half sinTheta = sqrt(1.0 - cosTheta * cosTheta);
                    float3 localDir = float3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);
                    float3 jitteredDir = localDir.x * t + localDir.y * b + localDir.z * reflectDir;
                    float3 viewspaceRayDir = normalize(lerp(reflectDir, jitteredDir, pow(roughness, 0.5h)));

                    half random_len_frac = frac(randomRotation + j * 0.379);
                    half ray_max_dist = lerp(0.1, _SSR_MaxRayDistance, random_len_frac);
                    
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
                        half dynamicThickness = _SSR_IntersectionThickness * saturate(sceneDepth * 0.1);

                        if (rayDepth > sceneDepth && (rayDepth - sceneDepth) < dynamicThickness && sceneDepth < 0.999 * _ProjectionParams.z)
                        {
                            half3 reflectedColor = tex2D(_CameraGBufferTexture3, currentUV).rgb;
                            float2 screenEdge = abs(currentUV - 0.5) * 2.0;
                            float fade = 1.0 - saturate(pow(max(screenEdge.x, screenEdge.y), 6.0));
                            
                            totalReflection += min(reflectedColor, (half3)_SSR_SampleClampValue) * fade;
                            hitCount += 1.0h;
                            
                            break;
                        }
                        currentRayLen *= stepGrowth;
                    }
                }
                
                if (_SSR_SampleCount > 0)
                {
                    half3 avg_all_samples = totalReflection / (half)_SSR_SampleCount;
                    half3 avg_hit_samples = (hitCount > 0) ? totalReflection / hitCount : 0;
                    totalReflection = lerp(avg_all_samples, avg_hit_samples, _SSR_RoughnessContrast);
                }

                return float4(totalReflection, 1.0);
            }
            ENDCG
        }
        
        // --- PASS 3: SSDCS (Directional Light Only) ---

        /*
        It still brokenly assumes a single directional light for now and doesn't read shadowmaps.
        It using directional position and color from the last light in the scene.
        This is obviously not ideal, but it's a limitation of the current Unity built-in rendering pipeline or my knowledge of it.
        A proper implementation would require a custom lighting pass or compute shader that has access to the
        */

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag_SSDCS
            
            half4 frag_SSDCS(v2f i, float4 screenPos : SV_Position) : SV_Target
            {
                if (readDepth(i.uv) >= 0.999 * _ProjectionParams.z) return 1.0h;

                float3 viewPos, viewNormal;
                getSceneData(i.uv, i.ray, viewPos, viewNormal);
                
                float3 viewspaceRayDir = -_SSDCS_LightDirVS;
                
                if (dot(viewNormal, viewspaceRayDir) <= 0.01h) return 1.0h;
                
                float3 origin = viewPos + viewNormal * 0.015h;
                
                half dither = getRandomRotation(screenPos) / (2.0 * PI);
                
                half currentRayLen = lerp(0.005, _SSDCS_MaxRayDistance * 0.1, dither);
                half stepSize = _SSDCS_MaxRayDistance / (half)_SSDCS_SampleCount;
                half receiverDepth = -viewPos.z;
                
                [loop]
                for(int j = 0; j < _SSDCS_SampleCount; j++)
                {
                    float3 currentRayPos = origin + viewspaceRayDir * currentRayLen;
                    float4 currentClip = mul(_Projection, float4(currentRayPos, 1.0));
                    float2 currentUV = (currentClip.xy / currentClip.w) * 0.5 + 0.5;
                    
                    if (saturate(currentUV).x != currentUV.x || saturate(currentUV).y != currentUV.y) break;
                    
                    half sceneDepth = readDepth(currentUV);
                    half rayDepth = -currentRayPos.z;
                    
                    if (sceneDepth + _SSDCS_Thickness < rayDepth)
                    {
                        if (abs(receiverDepth - sceneDepth) <= _SSDCS_MaxRayDistance * 2.0h)
                        {
                            return 0.0h; // Shadowed
                        }
                    }
                    
                    currentRayLen += stepSize;
                }
                
                return 1.0h; // Not shadowed
            }
            ENDCG
        }

        // --- PASS 4: SPATIAL BLUR ---
        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag_gaussian_blur

            half _BlurRadius, _BlurDepthWeight, _BlurNormalWeight;

            half4 frag_gaussian_blur(v2f i) : SV_Target
            {
                half centerDepth = readDepth(i.uv);
                if (centerDepth >= 0.999 * _ProjectionParams.z) return tex2D(_MainTex, i.uv);
                
                half rawDepth;
                half3 centerNormal;
                DecodeDepthNormal(tex2D(_CameraDepthNormalsTexture, i.uv), rawDepth, centerNormal);

                half4 total = 0.0h;
                half totalWeight = 0.0h;

                [unroll]
                for (int x = -1; x <= 2; x++) {
                    [unroll]
                    for (int y = -2; y <= 1; y++) {
                        half2 offset = half2(x, y) * _FullResTexelSize.xy * _BlurRadius;
                        half2 sampleUV = i.uv + offset;

                        half sampleDepth = readDepth(sampleUV);
                        half3 sampleNormal;
                        DecodeDepthNormal(tex2D(_CameraDepthNormalsTexture, sampleUV), rawDepth, sampleNormal);

                        half depthDiff = abs(centerDepth - sampleDepth);
                        half depthW = exp(-_BlurDepthWeight * depthDiff * depthDiff);

                        half normalDot = saturate(dot(centerNormal, sampleNormal));
                        half normalW = pow(normalDot, _BlurNormalWeight);

                        half dist = dot(offset, offset);
                        half gaussW = exp(-dist * 2.0);

                        half weight = gaussW * depthW * normalW;
                        total += tex2D(_MainTex, sampleUV) * weight;
                        totalWeight += weight;
                    }
                }
                
                if (totalWeight > 1e-4) return total / totalWeight;
                return tex2D(_MainTex, i.uv);
            }
            ENDCG
        }
    
        // --- PASS 5: TEMPORAL REPROJECTION ---
        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag_temporal
   
            float4 frag_temporal(v2f i) : SV_Target
            {
                float4 current = tex2D(_CurrentFrameTex, i.uv);
                float depth = readDepth(i.uv);
                if (depth >= 0.999 * _ProjectionParams.z) return current;

                float3 viewPos = i.ray * depth;
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
                            // I'm not sure why using _ScreenParams.xy here seems to work better than _FullResTexelSize.xy
                            // I'm sure it was a mistake at some point, but it seems to produce less ghosting artifacts in practice.
                            // So idk, maybe it's not a mistake? Leaving it as-is for now lol
                            // float2 offset = float2(x, y) * _ScreenParams.xy;
                            // It was the correct line
                            // float2 offset = float2(x, y) * _FullResTexelSize.xy;

                            // It looks better lol - leaving it like this for now
                            float2 offset = float2(x, y) * _FullResTexelSize.xy + _ScreenParams.xy;
                            
                            float4 s = tex2D(_CurrentFrameTex, i.uv + offset);
                            min_val = min(min_val, s);
                            max_val = max(max_val, s);
                        }
                    }

                    // Widen the clamp range to be more forgiving to high-frequency noise and reprojection errors.
                    // This reduces shimmering at the cost of allowing slightly more ghosting.
                    float4 range = max_val - min_val;
                    min_val -= range * 0.5h;
                    max_val += range * 0.5h;

                    history = clamp(history, min_val, max_val);
                    return lerp(current, history, _TemporalBlendFactor);
                }
                
                return current;
            }
            ENDCG
        }

        // --- PASS 6: COMPOSITE SSGI ---
        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            float4 frag(v2f i) : SV_Target
            {
                float4 originalColor = tex2D(_MainTex, i.uv);
                float3 indirectBouncedLight = tex2D(_EffectTex, i.uv).rgb;
                float3 albedo = tex2D(_CameraGBufferTexture0, i.uv).rgb;
                float3 finalIndirectTerm = indirectBouncedLight * albedo * (_SSGI_Intensity * 3);
                float luminance = dot(originalColor.rgb, float3(0.2126, 0.7152, 0.0722));
                float brightMask = saturate(1.0 - luminance);
                float3 finalColor = originalColor.rgb + finalIndirectTerm * brightMask;
                return float4(finalColor, originalColor.a);
            }
            ENDCG
        }
        
        // --- PASS 7: COMPOSITE SSAO ---
        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            float4 frag(v2f i) : SV_Target
            {
                float4 originalColor = tex2D(_MainTex, i.uv);
                half occlusion = tex2D(_EffectTex, i.uv).r;
                float luminance = dot(originalColor.rgb, float3(0.2126, 0.7152, 0.0722));
                half brightMask = saturate(1.0 - luminance);
                half finalOcclusion = lerp(1.0h, occlusion, brightMask);
                float3 finalColor = originalColor.rgb * finalOcclusion;
                return float4(finalColor, originalColor.a);
            }
            ENDCG
        }
        
        // --- PASS 8: COMPOSITE SSR ---
        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            float4 frag(v2f i) : SV_Target
            {
                float4 originalColor = tex2D(_MainTex, i.uv);
                float3 reflection = tex2D(_EffectTex, i.uv).rgb;
                
                half4 gbuffer1 = tex2D(_CameraGBufferTexture1, i.uv);
                half3 specularColor = gbuffer1.rgb; 
                half smoothness = gbuffer1.a;
                
                float3 viewNormal;
                half rawDepth;
                DecodeDepthNormal(tex2D(_CameraDepthNormalsTexture, i.uv), rawDepth, viewNormal);
                float3 viewPos = i.ray * LinearEyeDepth(rawDepth);
                float3 viewDir = normalize(viewPos);

                half fresnelTerm = pow(1.0 - saturate(dot(viewNormal, -viewDir)), 5.0);
                half3 F = specularColor + (max(smoothness, specularColor.r) - specularColor) * fresnelTerm;
                
                float3 finalReflection = reflection * F * _SSR_Intensity;
                float3 finalColor = originalColor.rgb + finalReflection;
                
                return float4(finalColor, originalColor.a);
            }
            ENDCG
        }

        // --- PASS 9: COMPOSITE SSDCS ---
        /* 
        Read previous note on the SSDCS pass. This is a very basic implementation that just darkens the scene based on the contact shadow factor / directional position.
        A more advanced implementation would read the actual light color, shadowmaps, and intensity from the main directional light and apply it properly.
        It would also need to account for multiple lights and their shadowmaps, which is not possible with the built-in rendering pipeline without a custom lighting pass for now.
        It also assumes the light direction is already in view space, which is not ideal! Use it with caution, it still causes contact shadows leaking in indoor areas or small bright places.
        */
        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
                    
            float4 frag(v2f i) : SV_Target
            {
                float4 originalColor = tex2D(_MainTex, i.uv);
                half contactShadow = tex2D(_EffectTex, i.uv).r;

                half luminance = dot(originalColor.rgb, half3(0.2126, 0.7152, 0.0722));

                half brightnessMask = saturate(luminance * 2.0h);

                half finalShadow = lerp(1.0h, contactShadow, brightnessMask);

                finalShadow = lerp(1.0h, finalShadow, _SSDCS_Intensity);
                float3 finalColor = originalColor.rgb * finalShadow;

                return float4(finalColor, originalColor.a);
            }
            ENDCG
        }
    }
}
