Shader "Hidden/SSBevel"
{
    Properties {
        _MainTex("Texture", 2D) = "white" {}
        _Intensity("Light Intensity", Range(0, 5)) = 1.0
        _DarkenIntensity("Dark Intensity", Range(0, 1)) = 0.5
        _ScaleWithDepth("Scale With Depth", Range(0, 1)) = 1.0
        _RimPower("Rim Power", Range(0.5, 8.0)) = 2.0
        _RimIntensity("Rim Intensity", Range(0, 2)) = 0.5
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

        struct v2f_fullres {
            float4 vertex : SV_POSITION;
            float2 uv : TEXCOORD0;
        };

        sampler2D _MainTex;
        sampler2D _CameraGBufferTexture0;
        sampler2D _CameraGBufferTexture1;
        sampler2D _CameraGBufferTexture2;
        sampler2D_float _CameraDepthTexture;
        sampler2D_float _CameraDepthNormalsTexture;
        float4x4 _InverseProjection, _PrevViewProjMatrix, _InverseView;
        half _UseTemporalDithering;
        float4 _FullResTexelSize;
        half _ScaleWithDepth;
        half _RimPower;
        half _RimIntensity;

        v2f vert(appdata v) {
            v2f o;
            o.vertex = UnityObjectToClipPos(v.vertex);
            o.uv = v.uv;
            o.ray = mul(_InverseProjection, float4(v.uv * 2 - 1, 0, 1)).xyz;
            return o;
        }

        v2f_fullres vert_fullres(appdata_base v) {
            v2f_fullres o;
            o.vertex = UnityObjectToClipPos(v.vertex);
            o.uv = v.texcoord;
            return o;
        }

        half readDepth(float2 coord) {
            return LinearEyeDepth(SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, coord));
        }
        
        void getSceneData(float2 uv, out float3 viewPos, out float3 viewNormal) {
            half depth = readDepth(uv);
            viewPos = mul(_InverseProjection, float4(uv * 2 - 1, 0, 1)).xyz * depth;
            half rawDepth;
            DecodeDepthNormal(tex2D(_CameraDepthNormalsTexture, uv), rawDepth, viewNormal);
        }

        // Function to extract world normal from GBuffer
        float3 getWorldNormal(float2 uv)
        {
            float3 worldNormal = tex2D(_CameraGBufferTexture2, uv).rgb * 2.0 - 1.0;
            return normalize(worldNormal);
        }

        // Function to calculate rim lighting effect
        float calculateRimEffect(float3 viewNormal, float3 viewDir, float power, float intensity)
        {
            float rim = 1.0 - saturate(dot(viewNormal, viewDir));
            rim = pow(rim, power) * intensity;
            return rim;
        }
        ENDCG

        // PASS 0: Edge Mask Generation
        Pass {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag_edge_mask

            int _SampleCount;
            half _Radius, _Sharpness, _DepthThreshold;

            float4 frag_edge_mask(v2f i, float4 screenPos : SV_Position) : SV_Target {
                half centerDepth = readDepth(i.uv);
                if (centerDepth >= 0.999 * _ProjectionParams.z) return 0;
                
                float3 centerViewPos, centerViewNormal;
                getSceneData(i.uv, centerViewPos, centerViewNormal);

                half depthScaledRadius = _Radius / centerViewPos.z * lerp(centerViewPos.z, 1.0, _ScaleWithDepth);

                half randomRotation;
                if (_UseTemporalDithering > 0.5h) {
                    float frameIndex = fmod(_Time.y * 60.0, 8.0);
                    float2 jitter = float2(frameIndex * 0.125, frameIndex * 0.125);
                    float dither = frac(52.9829189 * frac(0.06711056 * (screenPos.x + jitter.x) + 0.00583715 * (screenPos.y + jitter.y)));
                    randomRotation = dither * 2.0 * PI;
                } else {
                    float2 p = frac(screenPos.xy * float2(0.1031, 0.1030));
                    p += dot(p, p.yx + 19.19);
                    float static_hash = frac((p.x + p.y) * p.y);
                    randomRotation = static_hash * 2.0 * PI;
                }

                half edgeFactor = 0;
                
                [loop]
                for (int j = 0; j < _SampleCount; j++) {
                    float angle = 2.0 * PI * (float(j) / (float)_SampleCount) + randomRotation;
                    float sampleRadius = depthScaledRadius * sqrt(frac(randomRotation + j * 0.379));
                    float2 offset = float2(cos(angle), sin(angle)) * sampleRadius;
                    float2 sampleUV = i.uv + offset;

                    float3 sampleViewPos, sampleViewNormal;
                    getSceneData(sampleUV, sampleViewPos, sampleViewNormal);

                    half depthDiff = abs(centerViewPos.z - sampleViewPos.z);
                    half normalDot = saturate(dot(centerViewNormal, sampleViewNormal));

                    if (depthDiff < _DepthThreshold && normalDot < (1.0 - _Sharpness)) {
                        edgeFactor += 1.0h;
                    }
                }
                
                if (_SampleCount > 0) {
                    edgeFactor /= (half)_SampleCount;
                }
                
                return saturate(edgeFactor);
            }
            ENDCG
        }
        
        // PASS 1: Denoiser (Bilateral Gaussian Blur)
        Pass {
            CGPROGRAM
            #pragma vertex vert_fullres
            #pragma fragment frag_gaussian_blur
            sampler2D _BlurSourceTex;
            half _BlurRadius, _BlurDepthWeight, _BlurNormalWeight;
            half4 frag_gaussian_blur(v2f_fullres i) : SV_Target {
                half centerDepth = readDepth(i.uv);
                half rawDepth;
                half3 centerNormal;
                DecodeDepthNormal(tex2D(_CameraDepthNormalsTexture, i.uv), rawDepth, centerNormal);
                
                half4 total = 0.0h;
                half totalWeight = 0.0h;
                
                [unroll] for (int x = -2; x <= 2; x++) {
                    [unroll] for (int y = -2; y <= 2; y++) {
                        half2 offset = half2(x, y) * _FullResTexelSize.xy * _BlurRadius;
                        half2 sampleUV = i.uv + offset;
                        
                        half sampleDepth = readDepth(sampleUV);
                        half3 sampleNormal;
                        DecodeDepthNormal(tex2D(_CameraDepthNormalsTexture, sampleUV), rawDepth, sampleNormal);
                        
                        half depthDiff = abs(centerDepth - sampleDepth);
                        half depthW = exp(-_BlurDepthWeight * depthDiff * depthDiff);
                        half normalDot = saturate(dot(centerNormal, sampleNormal));
                        half normalW = pow(normalDot, 8);
                        half dist = dot(offset, offset);
                        half gaussW = exp(-dist);
                        
                        half weight = gaussW * depthW * normalW;
                        total += tex2D(_BlurSourceTex, sampleUV) * weight;
                        totalWeight += weight;
                    }
                }
                return (totalWeight > 1e-4) ? total / totalWeight : tex2D(_BlurSourceTex, i.uv);
            }
            ENDCG
        }

        // PASS 2: Temporal Reprojection
        Pass {
            CGPROGRAM
            #pragma vertex vert_fullres
            #pragma fragment frag_temporal
            sampler2D _CurrentFrameTex, _HistoryTex;
            half _TemporalBlendFactor;
            float4 frag_temporal(v2f_fullres i) : SV_Target {
                float4 current = tex2D(_CurrentFrameTex, i.uv);
                float depth = readDepth(i.uv);
                
                float3 viewRay = mul(_InverseProjection, float4(i.uv * 2 - 1, 0, 1)).xyz;
                float3 viewPos = viewRay * depth;
                float4 worldPos = mul(_InverseView, float4(viewPos, 1.0));
                float4 prevClipPos = mul(_PrevViewProjMatrix, worldPos);
                float2 prevUV = (prevClipPos.xy / prevClipPos.w) * 0.5 + 0.5;
                
                if (saturate(prevUV).x == prevUV.x && saturate(prevUV).y == prevUV.y) {
                    float4 history = tex2D(_HistoryTex, prevUV);
                    float4 center = tex2D(_CurrentFrameTex, i.uv);
                    float4 min_val = center, max_val = center;
                    [unroll] for (int x = -1; x <= 1; x++) {
                        [unroll] for (int y = -1; y <= 1; y++) {
                            float2 offset = float2(x, y) * _FullResTexelSize.xy;
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
        
        // PASS 3: Final Composite (Improved for unlit areas)
        Pass {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag_composite

            sampler2D _AccumulatedBevelTex;
            half _Intensity;
            half _DarkenIntensity;

            float4 frag_composite(v2f i) : SV_Target {
                float4 originalColor = tex2D(_MainTex, i.uv);
                half depth = readDepth(i.uv);
                if (depth >= 0.999 * _ProjectionParams.z) {
                    return originalColor;
                }
                
                float3 viewPos, viewNormal;
                getSceneData(i.uv, viewPos, viewNormal);
                
                // Get world normal from GBuffer for more accurate lighting calculations
                float3 worldNormal = getWorldNormal(i.uv);
                
                // Calculate view direction
                float3 viewDir = normalize(-viewPos);
                
                // Calculate rim lighting effect for unlit areas
                float rimEffect = calculateRimEffect(viewNormal, viewDir, _RimPower, _RimIntensity);
                
                float bevelMask = tex2D(_AccumulatedBevelTex, i.uv).r;
                
                // Get scene lighting information from GBuffer
                float3 diffuseColor = tex2D(_CameraGBufferTexture0, i.uv).rgb;
                float3 specularColor = tex2D(_CameraGBufferTexture1, i.uv).rgb;
                float lightLuminance = length(diffuseColor + specularColor) * 0.5;
                
                // Enhanced bevel effect that works in both lit and unlit areas
                float3 litBevelEffect = originalColor.rgb * bevelMask * _Intensity * 2.5;
                float3 unlitBevelEffect = originalColor.rgb * bevelMask * _DarkenIntensity;
                
                // Combine rim lighting with bevel effect for unlit areas
                float3 rimBevelEffect = rimEffect * bevelMask * _Intensity * originalColor.rgb;
                
                // Blend between effects based on scene lighting
                float lightingFactor = saturate(lightLuminance * 4.0);
                float3 finalBevelEffect = lerp(
                    rimBevelEffect - unlitBevelEffect * (1.0 - rimEffect), 
                    litBevelEffect, 
                    lightingFactor
                );
                
                float3 finalColor = originalColor.rgb + finalBevelEffect;
                
                return float4(finalColor, originalColor.a);
            }
            ENDCG
        }

        // PASS 4: Copy
        Pass {
            CGPROGRAM
            #pragma vertex vert_fullres
            #pragma fragment frag_copy
            float4 frag_copy(v2f_fullres i) : SV_Target {
                return tex2D(_MainTex, i.uv);
            }
            ENDCG
        }
    }
}