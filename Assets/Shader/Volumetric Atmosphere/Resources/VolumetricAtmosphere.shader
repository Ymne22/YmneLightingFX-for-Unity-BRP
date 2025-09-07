Shader "Hidden/VolumetricAtmosphere"
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

        // -- - Global Samplers and Uniforms -- -
        sampler2D_float _CameraDepthTexture;
        sampler2D_float _CameraDepthNormalsTexture;

        sampler2D _MainTex;
        sampler2D _CloudTex;
        sampler2D _BlurSourceTex;
        sampler2D _CurrentFrameTex;
        sampler2D _HistoryTex;
        sampler2D _GodRayTex;

        float4x4 _InverseProjection, _InverseView, _PrevViewProjMatrix;
        float4 _LowResScreenParams;
        float4 _FullResTexelSize;

        // Cloud uniforms
        float _CloudMinHeight, _CloudMaxHeight;
        float3 _NoiseSeedOffset;
        float3 _WindDirection;
        float _WindSpeed, _Density, _LightAbsorption, _NoiseScale, _Coverage, _CloudMorphSpeed;
        float4 _CloudColor, _SunColor, _SkyColor;
        float3 _LightDir;
        float _DetailIntensity, _Softness, _DetailNoiseScale, _Curliness;
        float _SilverLiningIntensity, _SilverLiningSpread, _SelfShadowStrength, _PlanetRadius;
        float _FadeStartDistance, _FadeEndDistance;
        int _Steps, _LightSteps;
        half _TemporalBlendFactor;
        half _UseTemporalDithering;

        // Blur uniforms
        half _BlurRadius, _BlurDepthWeight, _BlurNormalWeight;

        // Fog uniforms
        float4 _FogColor, _LightColor;
        float _FogIntensity, _FogDensity, _FogStart, _FogHeightStart, _FogHeightEnd;
        float _SunGlowIntensity;

        // God Ray uniforms
        float4 _LightScreenPos;
        float _GodRayWeight, _GodRayIntensity;
        int _GodRaySamples;
        float4 _GodRayColor;

        // -- - Structs and Vertex Shaders -- -
        struct v2f {
            float4 vertex : SV_POSITION;
            float3 ray : TEXCOORD0;
        };

        struct v2f_fullres
        {
            float4 vertex : SV_POSITION;
            float2 uv : TEXCOORD0;
        };

        v2f_fullres vert_fullres(appdata_base v)
        {
            v2f_fullres o;
            o.vertex = UnityObjectToClipPos(v.vertex);
            o.uv = v.texcoord;
            return o;
        }

        struct v2f_fog
        {
            float4 pos : SV_POSITION;
            float2 uv : TEXCOORD0;
            float3 viewVector : TEXCOORD1;
        };

        v2f_fog vert_scene_fog(appdata_base v)
        {
            v2f_fog o;
            o.pos = UnityObjectToClipPos(v.vertex);
            o.uv = v.texcoord.xy;
            o.viewVector = mul(unity_CameraInvProjection, float4(v.texcoord.xy * 2 - 1, 0, - 1)).xyz;
            o.viewVector = mul(unity_CameraToWorld, float4(o.viewVector, 0)).xyz;
            return o;
        }

        // -- - Helper Functions -- -
        half readDepth(float2 coord) { return LinearEyeDepth(SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, coord)); }
        float hash(float3 p) { p = frac(p * 0.3183099 + 0.1); p *= 17.0; return frac(p.x * p.y * p.z * (p.x + p.y + p.z)); }
        float noise(float3 x) { float3 i = floor(x); float3 f = frac(x); f = f * f * (3.0 - 2.0 * f); return lerp(lerp(lerp(hash(i + float3(0, 0, 0)), hash(i + float3(1, 0, 0)), f.x), lerp(hash(i + float3(0, 1, 0)), hash(i + float3(1, 1, 0)), f.x), f.y), lerp(lerp(hash(i + float3(0, 0, 1)), hash(i + float3(1, 0, 1)), f.x), lerp(hash(i + float3(0, 1, 1)), hash(i + float3(1, 1, 1)), f.x), f.y), f.z); }
        float fbm(float3 p, int octaves) { float v = 0.0; float a = 0.5; for (int i = 0; i < octaves; i ++) { v += a * noise(p); p *= 2.0; a *= 0.5; } return v; }
        float3 curlNoise(float3 p) { const float e = 0.1; float3 dx = float3(e, 0, 0); float3 dy = float3(0, e, 0); float3 dz = float3(0, 0, e); float fbm_p = fbm(p, 1); float fbm_px = fbm(p + dx, 1); float fbm_py = fbm(p + dy, 1); float fbm_pz = fbm(p + dz, 1); float x = fbm_py - fbm_pz; float y = fbm_pz - fbm_px; float z = fbm_px - fbm_py; return normalize(float3(x, y, z)) / e; }

        float cloud_density(float3 pos) {
            float3 samplePos = ((pos + _NoiseSeedOffset) + _WindDirection * _WindSpeed * _Time.y) * _NoiseScale * 0.001;
            samplePos += float3(0, 0, _Time.y * _CloudMorphSpeed);
            float baseShape = fbm(samplePos, 4);
            baseShape = saturate((baseShape - _Coverage) / max(0.001, 1.0 - _Coverage));
            if (baseShape < 0.01) return 0.0;
            float mediumDetail = fbm(samplePos * _DetailNoiseScale, 3) * _DetailIntensity;
            baseShape = saturate(baseShape - mediumDetail);
            float3 curlPos = samplePos * _Curliness;
            float3 curl = curlNoise(curlPos) * 0.1;
            baseShape = saturate(baseShape + curl.x * 0.1);
            float height;
            #if defined(USE_CURVATURE)
            float3 planetCenter = float3(0, - _PlanetRadius, 0);
            height = (length(pos - planetCenter) - _PlanetRadius - _CloudMinHeight) / (_CloudMaxHeight - _CloudMinHeight);
            #else
            height = (pos.y - _CloudMinHeight) / (_CloudMaxHeight - _CloudMinHeight);
            #endif
            float heightFactor = smoothstep(0.0, 0.15, height) * (1.0 - smoothstep(0.8, 1.0, height));
            return saturate(baseShape * heightFactor * _Density * _Softness);
        }

        float beerLaw(float d) { return exp(- d * _LightAbsorption); }
        float2 raySphereIntersect(float3 rayOrigin, float3 rayDir, float3 sphereCenter, float radius) {
            float3 oc = rayOrigin - sphereCenter;
            float b = dot(oc, rayDir); float c = dot(oc, oc) - radius * radius;
            float discriminant = b * b - c;
            if (discriminant < 0.0) return float2(- 1.0, - 1.0);
            else { float sqrt_d = sqrt(discriminant); return float2(- b - sqrt_d, - b + sqrt_d); }
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

        half3 get_fog(float3 worldPos, float3 viewDir, out half fogFactor)
        {
            float linearDepth = length(worldPos - _WorldSpaceCameraPos);
            float fogDistance = max(0, linearDepth - _FogStart);
            float distanceFog = 1.0 - exp(- _FogDensity * fogDistance * fogDistance);
            float heightFactor = saturate((worldPos.y - _FogHeightStart) / (_FogHeightEnd - _FogHeightStart));
            float heightFog = exp(- heightFactor * 4.0);
            fogFactor = saturate(distanceFog * heightFog) * _FogIntensity;

            half3 finalFogColor = _FogColor.rgb;
            #if defined(DIRECTIONAL_LIGHT_ON)
            float scatter = saturate(dot(viewDir, normalize(_LightDir)));
            float sunGlow = pow(scatter, 32.0);
            finalFogColor += _LightColor.rgb * sunGlow * _SunGlowIntensity;
            #endif
            return finalFogColor;
        }
        ENDCG

        // PASS 0 : Raymarch Clouds
        Pass {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile __ ENABLE_CLOUDS
            #pragma multi_compile __ DIRECTIONAL_LIGHT_ON
            #pragma shader_feature USE_CURVATURE
            #pragma shader_feature USE_DISTANCE_FADE

            v2f vert(appdata_base v) {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.ray = mul(_InverseProjection, float4(v.texcoord.xy * 2 - 1, 0, 1)).xyz;
                return o;
            }

            float4 frag(v2f i, float4 screenPos : SV_Position) : SV_Target {
                #if !defined(ENABLE_CLOUDS)
                return float4(0, 1, 0, 1);
                #endif

                float sceneDepth = readDepth(i.vertex.xy / _LowResScreenParams.xy);
                float effectiveDepth = sceneDepth;
                if (sceneDepth >= _ProjectionParams.z * 0.999) {
                    #if defined(USE_DISTANCE_FADE)
                    effectiveDepth = _FadeEndDistance;
                    #else
                    effectiveDepth = 100000.0;
                    #endif
                }
                float3 rayDir = normalize(mul((float3x3)_InverseView, i.ray));
                float3 rayOrigin = _WorldSpaceCameraPos;
                float tMin, tMax;
                #if defined(USE_CURVATURE)
                float3 planetCenter = float3(0, - _PlanetRadius, 0);
                float r_max = _PlanetRadius + _CloudMaxHeight;
                float2 t_outer = raySphereIntersect(rayOrigin, rayDir, planetCenter, r_max);
                if (t_outer.y < 0.0) return float4(0, 1, 0, 1);
                tMin = max(0.0, t_outer.x); tMax = min(effectiveDepth, t_outer.y);
                #else
                float distToMinHeight = (_CloudMinHeight - rayOrigin.y) / rayDir.y;
                float distToMaxHeight = (_CloudMaxHeight - rayOrigin.y) / rayDir.y;
                tMin = max(0, min(distToMinHeight, distToMaxHeight)); tMax = min(effectiveDepth, max(distToMinHeight, distToMaxHeight));
                if (abs(rayDir.y) < 0.001) { if(rayOrigin.y < _CloudMinHeight || rayOrigin.y > _CloudMaxHeight) return float4(0,1,0,1); tMin = 0; tMax = effectiveDepth; }
                #endif
                if(tMin >= tMax) return float4(0, 1, 0, 1);
                float stepSize = (tMax - tMin) / _Steps;
                float4 finalCloudColor = 0; float transmittance = 1.0;

                float randomRotation = getRandomRotation(screenPos);
                float t = tMin + stepSize * randomRotation;
                for(int s = 0; s < _Steps; s ++, t += stepSize) {
                    if (t > tMax || transmittance < 0.01) break;
                    float3 pos = rayOrigin + rayDir * t;
                    float density = cloud_density(pos);
                    #if defined(USE_DISTANCE_FADE)
                    density *= smoothstep(_FadeEndDistance, _FadeStartDistance, t);
                    #endif

                    if (density > 0.01) {
                        float3 cloudColor;
                        if (length(_SunColor.rgb) > 0.01) {
                            float lightDensity = 0;
                            float lightStepSize = 96.0;
                            for(int ls = 0; ls < _LightSteps; ls ++) lightDensity += cloud_density(pos + _LightDir * lightStepSize * (ls + 0.5)) * lightStepSize;
                            float lightEnergy = beerLaw(lightDensity * _SelfShadowStrength);
                            float phase = saturate(dot(rayDir, - _LightDir));
                            float silverLining = pow(saturate(dot(normalize(rayDir - _LightDir), - _LightDir)), _SilverLiningSpread) * _SilverLiningIntensity;
                            float3 lightColor = lerp(_SkyColor.rgb, _SunColor.rgb, lightEnergy) + UNITY_LIGHTMODEL_AMBIENT.rgb;
                            cloudColor = _CloudColor.rgb * lightColor * (phase + silverLining);
                        } else {
                            cloudColor = _CloudColor.rgb * UNITY_LIGHTMODEL_AMBIENT.rgb * 0.5f;
                        }

                        half fogFactor;
                        half3 fogColor = get_fog(pos, - rayDir, fogFactor);
                        cloudColor = lerp(cloudColor, fogColor, fogFactor);

                        float stepTransmittance = exp(- density * stepSize);
                        finalCloudColor.rgb += cloudColor * (1.0 - stepTransmittance) * transmittance;
                        transmittance *= stepTransmittance;
                    }
                }
                float finalAlpha = 1.0 - transmittance;
                float3 keyColor = float3(0, 1, 0);
                float3 pureCloudColor = finalCloudColor.rgb / (finalAlpha + 1e-6f);
                float3 outputColor = lerp(keyColor, pureCloudColor, finalAlpha);
                return float4(outputColor, 1.0);
            }
            ENDCG
        }

        // PASS 1 : Composite Clouds onto Scene
        Pass {
            CGPROGRAM
            #pragma vertex vert_fullres
            #pragma fragment frag_composite

            float4 frag_composite(v2f_fullres i) : SV_Target {
                float4 sceneColor = tex2D(_MainTex, i.uv);
                float4 cloudRender = tex2D(_CloudTex, i.uv);

                float alpha = saturate(1.0 - (cloudRender.g - cloudRender.r));
                float luminance = cloudRender.r / (alpha + 1e-6f);
                float3 pureCloudColor = float3(luminance, luminance, luminance);

                float3 finalColor = lerp(sceneColor.rgb, pureCloudColor, alpha);
                return float4(finalColor, sceneColor.a);
            }
            ENDCG
        }

        // PASS 2 : Bilateral Gaussian Blur (Used for both clouds and god rays)
        Pass {
            CGPROGRAM
            #pragma vertex vert_fullres
            #pragma fragment frag_gaussian_blur

            half4 frag_gaussian_blur(v2f_fullres i) : SV_Target {
                half centerDepth = readDepth(i.uv);
                half rawDepth; half3 centerNormal; DecodeDepthNormal(tex2D(_CameraDepthNormalsTexture, i.uv), rawDepth, centerNormal);
                half4 total = 0.0h; half totalWeight = 0.0h;

                [unroll]
                for (int x = - 1; x <= 2; x ++) {
                    [unroll]
                    for (int y = - 2; y <= 1; y ++) {
                        half2 offset = half2(x, y) * _FullResTexelSize.xy * _BlurRadius;
                        half2 sampleUV = i.uv + offset;
                        half sampleDepth = readDepth(sampleUV); half3 sampleNormal; DecodeDepthNormal(tex2D(_CameraDepthNormalsTexture, sampleUV), rawDepth, sampleNormal);
                        half depthDiff = abs(centerDepth - sampleDepth); half depthW = exp(- _BlurDepthWeight * depthDiff * depthDiff);
                        half normalDot = saturate(dot(centerNormal, sampleNormal));
                        half normalW = pow(normalDot, _BlurNormalWeight);
                        half dist = dot(offset, offset); half gaussW = exp(- dist);
                        half weight = gaussW * depthW * normalW;
                        total += tex2D(_BlurSourceTex, sampleUV) * weight; totalWeight += weight;
                    }
                }
                return (totalWeight > 1e-4) ? total / totalWeight : tex2D(_BlurSourceTex, i.uv);
            }
            ENDCG
        }

        // PASS 3 : Temporal Reprojection
        Pass {
            CGPROGRAM
            #pragma vertex vert_fullres
            #pragma fragment frag_temporal

            float4 frag_temporal(v2f_fullres i) : SV_Target {
                float4 current = tex2D(_CurrentFrameTex, i.uv);
                float depth = readDepth(i.uv);
                float3 viewRay = mul(_InverseProjection, float4(i.uv * 2 - 1, 0, 1)).xyz;
                float3 viewPos = viewRay * depth; float4 worldPos = mul(_InverseView, float4(viewPos, 1.0));
                float4 prevClipPos = mul(_PrevViewProjMatrix, worldPos);
                float2 prevUV = (prevClipPos.xy / prevClipPos.w) * 0.5 + 0.5;
                if (saturate(prevUV).x == prevUV.x && saturate(prevUV).y == prevUV.y) {
                    float4 history = tex2D(_HistoryTex, prevUV);
                    return lerp(current, history, _TemporalBlendFactor);
                }
                return current;
            }
            ENDCG
        }

        // PASS 4 : Copy
        Pass {
            CGPROGRAM
            #pragma vertex vert_fullres
            #pragma fragment frag_copy

            float4 frag_copy(v2f_fullres i) : SV_Target { return tex2D(_MainTex, i.uv); }
            ENDCG
        }

        // PASS 5 : Global Scene Fog
        Pass
        {
            CGPROGRAM
            #pragma vertex vert_scene_fog
            #pragma fragment frag_scene_fog
            #pragma multi_compile __ ENABLE_FOG
            #pragma multi_compile __ DIRECTIONAL_LIGHT_ON
            #pragma multi_compile __ FOG_INCLUDE_SKYBOX

            half4 frag_scene_fog(v2f_fog i) : SV_Target
            {
                half4 sceneColor = tex2D(_MainTex, i.uv);
                #if !defined(ENABLE_FOG)
                return sceneColor;
                #endif

                float rawDepth = readDepth(i.uv);
                float fogDepth;

                bool isSkybox = (rawDepth >= _ProjectionParams.z * 0.999);
                if (isSkybox)
                {
                    #if !FOG_INCLUDE_SKYBOX
                    return sceneColor;
                    #endif
                    fogDepth = 1000.0;
                }
                else
                {
                    fogDepth = rawDepth;
                }

                float3 worldPos = _WorldSpaceCameraPos + fogDepth * normalize(i.viewVector);
                float3 viewDir = normalize(worldPos - _WorldSpaceCameraPos);

                half fogFactor;
                half3 fogColor = get_fog(worldPos, viewDir, fogFactor);

                return half4(lerp(sceneColor.rgb, fogColor, fogFactor), sceneColor.a);
            }
            ENDCG
        }

        // PASS 6 : God Ray Mask Generation
        Pass
        {
            CGPROGRAM
            #pragma vertex vert_fullres
            #pragma fragment frag

            half4 frag(v2f_fullres i) : SV_Target
            {
                float sceneDepth = readDepth(i.uv);
                if (sceneDepth < _ProjectionParams.z * 0.999)
                {
                    return 0; //
                }

                float dist = distance(i.uv, _LightScreenPos.xy);
                float sunGlow = 1.0 - saturate(dist / 0.15);
                sunGlow *= sunGlow;

                half4 cloudRender = tex2D(_CloudTex, i.uv);
                float cloudOpacity = saturate(1.0 - (cloudRender.g - cloudRender.r));
                float finalGlow = sunGlow * (1.0 - cloudOpacity);
                
                return _GodRayColor * finalGlow;
            }
            ENDCG
        }

        // PASS 7 : God Ray Radial Blur
        Pass
        {
            CGPROGRAM
            #pragma vertex vert_fullres
            #pragma fragment frag
            #pragma target 3.0

            half4 frag(v2f_fullres i) : SV_Target
            {
                float2 delta = _LightScreenPos.xy - i.uv;
                delta /= _GodRaySamples;

                half4 color = 0;

                for (int s = 0; s < _GodRaySamples; s ++)
                {
                    float2 sampleUV = i.uv + delta * s;
                    half4 sampleColor = tex2D(_MainTex, sampleUV);
                    sampleColor *= _GodRayWeight;
                    color += sampleColor;
                }

                return color / _GodRaySamples;
            }
            ENDCG
        }

        // PASS 8 : God Ray Composite (Improved)
        Pass
        {
            CGPROGRAM
            #pragma vertex vert_fullres
            #pragma fragment frag
          
            #pragma multi_compile __ ENABLE_GODRAYS
            // No longer need the shader_feature for blend modes

            half4 frag(v2f_fullres i) : SV_Target
            {
                half4 sceneColor = tex2D(_MainTex, i.uv);
                #if defined(ENABLE_GODRAYS)
                    half4 godRayColor = tex2D(_GodRayTex, i.uv);

                    // Keep the depth-based occlusion
                    float sceneDepth = readDepth(i.uv);
                    float skyMask = smoothstep(_ProjectionParams.z * 0.98, _ProjectionParams.z, sceneDepth);
                    godRayColor.rgb *= skyMask;
                    
                    // Apply intensity
                    godRayColor.rgb *= _GodRayIntensity;

                    // Permanently use Additive blending
                    sceneColor.rgb += godRayColor.rgb;
                #endif

                return sceneColor;
            }
            ENDCG
        }
    }
}

