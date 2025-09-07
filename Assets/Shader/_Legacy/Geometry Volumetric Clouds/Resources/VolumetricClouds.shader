Shader "Custom/VolumetricClouds" {
    Properties {
        _Density ("Cloud Density", Range(0.1, 5)) = 1.0
        _CloudMinHeight ("Cloud Min Height", Range(100, 5000)) = 1500
        _CloudMaxHeight ("Cloud Max Height", Range(100, 5000)) = 3500
        _LightAbsorption ("Light Absorption", Range(0.1, 10)) = 2.0
        _WindSpeed ("Wind Speed", Range(0, 100)) = 20
        _WindDirection ("Wind Direction", Vector) = (1, 0, 0, 0)
        _Steps ("Raymarch Steps", Range(8, 128)) = 64
        _LightSteps ("Light Steps", Range(1, 16)) = 6
        _NoiseScale ("Noise Scale", Range(0.1, 10)) = 1.0
        _Coverage ("Cloud Coverage", Range(0, 1)) = 0.5
        _CloudColor ("Cloud Color", Color) = (0.9, 0.9, 1.0, 1)
        _SunColor ("Sun Color", Color) = (1, 0.9, 0.8, 1)
        _SkyColor ("Sky Color", Color) = (0.4, 0.6, 1.0, 1)
        _AmbientColor ("Ambient Color", Color) = (0.4, 0.5, 0.7, 1)
        _EditorIntensity ("Editor Intensity", Range(1, 3)) = 1.5
        _VolumeSize ("Volume Size", Float) = 10000
        _DetailIntensity ("Detail Intensity", Range(0, 1)) = 0.3
        _Softness ("Cloud Softness", Range(0.1, 2)) = 0.8
        _HDRExposure ("HDR Exposure", Range(0.1, 3)) = 1.0
        _DetailNoiseScale ("Detail Noise Scale", Range(0.1, 20)) = 5.0
        _Curliness ("Cloud Curliness", Range(0.1, 5)) = 1.0
        _CloudAttenuation ("Cloud Attenuation", Range(0, 1)) = 0.5
        _SilverLiningIntensity ("Silver Lining Intensity", Range(0, 2)) = 0.8
        _SilverLiningSpread ("Silver Lining Spread", Range(0, 1)) = 0.5
        _MaxDistance ("Max Raymarch Distance", Float) = 4096
        _StepSmoothing ("Step Smoothing", Range(0, 1)) = 0.5
        _CloudMorphSpeed ("Cloud Morph Speed", Range(0, 0.1)) = 0.02
    }

    SubShader {
        Tags { 
            "Queue"="Transparent+100" 
            "RenderType"="Transparent" 
            "IgnoreProjector"="True"
            "ForceNoShadowCasting"="True"
        }
        LOD 100

        Pass {
            Name "FORWARD"
            Tags { "LightMode" = "ForwardBase" }
            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite Off
            ZTest LEqual
            Cull Off

            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_fwdbase
            #pragma multi_compile_fog
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile _ _EDITOR_MODE
            
            #include "UnityCG.cginc"
            #include "Lighting.cginc"
            #include "AutoLight.cginc"

            sampler2D_float _CameraDepthTexture;
            
            // Properties
            float _Density;
            float _CloudMinHeight;
            float _CloudMaxHeight;
            float _LightAbsorption;
            float _WindSpeed;
            float4 _WindDirection;
            int _Steps;
            int _LightSteps;
            float _NoiseScale;
            float4 _CloudColor;
            float4 _SunColor;
            float4 _SkyColor;
            float4 _AmbientColor;
            float _EditorIntensity;
            float _VolumeSize;
            float _Coverage;
            float _DetailIntensity;
            float _Softness;
            float _HDRExposure;
            float _DetailNoiseScale;
            float _Curliness;
            float _CloudAttenuation;
            float _SilverLiningIntensity;
            float _SilverLiningSpread;
            float _MaxDistance;
            float _StepSmoothing;
            float _CloudMorphSpeed;
            
            // Precomputed values
            float _InvHeightRange;
            float3 _WindOffset;

            uint sobol(uint n, uint seed) {
                for (uint i = 0; i < 32; i++) {
                    if (n & 1) seed ^= (1u << (31 - i));
                    n >>= 1;
                }
                return seed;
            }

            float sobol2d(uint2 pixelCoord, uint frameIndex) {
                uint x = sobol(pixelCoord.x, 0x00008000u);
                uint y = sobol(pixelCoord.y, 0x00004000u);
                uint z = sobol(frameIndex,   0x00002000u);
                return float((x ^ y ^ z) >> 16) / 65536.0;
            }
            
            float hash(float3 p) {
                p = frac(p * 0.3183099 + 0.1);
                p *= 16.0;
                return frac(p.x * p.y * p.z * (p.x + p.y + p.z));
            }

            float3 hash3(float3 p) {
                float x = dot(p, float3(127.1, 311.7, 74.7));
                float y = dot(p, float3(269.5, 183.3, 246.1));
                float z = dot(p, float3(113.5, 271.9, 124.6));
                return frac(sin(float3(x, y, z)) * 43758.5453);
            }
            
            float noise(float3 x) {
                float3 i = floor(x);
                float3 f = frac(x);
                f = f * f * (3.0 - 2.0 * f);
                return lerp(
                    lerp(
                        lerp(hash(i + float3(0,0,0)), hash(i + float3(1,0,0)), f.x),
                        lerp(hash(i + float3(0,1,0)), hash(i + float3(1,1,0)), f.x),
                        f.y
                    ),
                    lerp(
                        lerp(hash(i + float3(0,0,1)), hash(i + float3(1,0,1)), f.x),
                        lerp(hash(i + float3(0,1,1)), hash(i + float3(1,1,1)), f.x),
                        f.y
                    ),
                    f.z
                );
            }
            
            float fbm(float3 p, int octaves) {
                float value = 0.0;
                float amplitude = 0.5;
                float frequency = 1.0;
                float maxAmplitude = 0.0;
                for (int i = 0; i < octaves; i++) {
                    value += amplitude * noise(p * frequency);
                    if (value > 1.5) break;
                    maxAmplitude += amplitude;
                    amplitude *= 0.5;
                    frequency *= 2.0;
                }
                return value / maxAmplitude;
            }

            float worleyNoise(float3 p, float scale) {
                p *= scale;
                float3 pInt = floor(p);
                float3 pFrac = frac(p);
                float minDist = 1.0;

                // 3x3x3 neighborhood
                for (int z = -1; z <= 1; z++) {
                    for (int y = -1; y <= 1; y++) {
                        for (int x = -1; x <= 1; x++) {
                            float3 neighbor = float3(x, y, z);
                            float3 randomPoint = hash3(pInt + neighbor);
                            float3 diff = neighbor + randomPoint - pFrac;
                            float dist = length(diff);
                            minDist = min(minDist, dist);
                        }
                    }
                }
                return minDist;
            }
            
            float worleyBase(float3 p, float scale) {
                p *= scale;
                float3 pInt = floor(p);
                float3 pFrac = frac(p);
                float minDist = 1.0;

                // 3x3x3 neighborhood
                for (int z = -1; z <= 1; z++) {
                    for (int y = -1; y <= 1; y++) {
                        for (int x = -1; x <= 1; x++) {
                            float3 neighbor = float3(x, y, z);
                            float3 randomPoint = hash3(pInt + neighbor);
                            float3 diff = neighbor + randomPoint - pFrac;
                            float dist = length(diff);
                            minDist = min(minDist, dist);
                        }
                    }
                }
                return minDist;
            }

            float worleyCombine(float3 p) {
                // --- domain warp with low frequency noise ---
                float3 warp = hash3(floor(p * 0.25)) * 2.0 - 1.0;  // cheap hash warp
                p += warp * 0.5;

                // --- multiple scales ---
                float w1 = worleyBase(p, 1.0);
                float w2 = worleyBase(p, 2.0);
                float w3 = worleyBase(p, 4.0);

                // --- invert some for blob breakup ---
                w1 = 1.0 - w1;
                w2 = 1.0 - w2;

                // --- weighted blend ---
                float combined = (w1 * 0.55 + w2 * 0.3 + w3 * 0.15);

                // --- shaping: soften + density bias ---
                combined = smoothstep(0.25, 0.85, combined);
                combined = pow(combined, 1.35);

                return combined;
            }
            
            float3 curlNoise(float3 p) {
                const float e = 0.1;
                float3 dx = float3(e, 0, 0);
                float3 dy = float3(0, e, 0);
                float3 dz = float3(0, 0, e);
                float fbm_p = fbm(p, 1);
                float fbm_px = fbm(p + dx, 1);
                float fbm_py = fbm(p + dy, 1);
                float fbm_pz = fbm(p + dz, 1);

                float x = fbm_py - fbm_pz;
                float y = fbm_pz - fbm_px;
                float z = fbm_px - fbm_py;

                return normalize(float3(x, y, z)) / e;
            }
            
            void PrecomputeValues() {
                _InvHeightRange = 1.0 / (_CloudMaxHeight - _CloudMinHeight);
                _WindOffset = normalize(_WindDirection.xyz) * _WindSpeed * _Time.y;
            }
            
            // --- Cloud density function ---
            float cloud_density(float3 pos) {
                float3 samplePos = (pos + _WindOffset) * _NoiseScale * 0.001;
                samplePos += float3(-125.9321, 532.123128, 312.142389) + float3(_Time.y * -0.5, _Time.y * 0.2, _Time.y * 0.3) * _CloudMorphSpeed;
                
                float baseShape = fbm(samplePos, 1);
                baseShape = saturate(baseShape - _Coverage) / max(0.1, 1.0 - _Coverage);

                if (baseShape < 0.01) return 0.0;
                float3 mediumDetailPos = samplePos * _DetailNoiseScale;
                
                //Uncomment the line below to use single octave worley noise for medium detail instead, experiment with both to see which you prefer. 
                //Good balance between quality and performance
                //float mediumDetail = worleyNoise(mediumDetailPos, 1.0) * _DetailIntensity;

                //Uncomment the line below to use worley FBM for medium detail instead, experiment with both to see which you prefer. 
                //Best visual quality option but more expensive
                //float mediumDetail = worleyCombine(mediumDetailPos) * _DetailIntensity;

                //Uncomment the line below to use FBM only for medium detail instead, experiment with both to see which you prefer. 
                //Best performance option!
                float mediumDetail = fbm(mediumDetailPos, 3) * _DetailIntensity;

                baseShape = saturate(baseShape - mediumDetail * 0.3);
                float3 fineDetailPos = samplePos * _DetailNoiseScale * 3.0;
                float fineDetail = fbm(fineDetailPos, 1) * _DetailIntensity * 0.5;

                baseShape = saturate(baseShape - fineDetail * 0.2);
                float3 curlPos = samplePos * _Curliness;
                float3 curl = curlNoise(curlPos) * 0.1;

                baseShape = saturate(baseShape + curl.x * 0.1);
                float height = (pos.y - _CloudMinHeight) * _InvHeightRange;
                float heightFactor = smoothstep(0.0, 0.2, height) * (1.0 - smoothstep(0.7, 1.0, height));

                baseShape *= heightFactor;
                float edgeFalloff = smoothstep(0.0, 0.10, baseShape) * (0.5 - smoothstep(0.8, 1.0, baseShape));
                baseShape *= edgeFalloff;

                #if defined(_EDITOR_MODE)
                baseShape *= _EditorIntensity;
                #endif

                return saturate(baseShape * _Density * _Softness);
            }
            
            struct Ray {
                float3 origin;
                float3 direction;
            };
            
            float2 rayBoxIntersection(float3 origin, float3 direction, float3 boxMin, float3 boxMax) {
                float3 invDir = 1.0 / max(abs(direction), 1e-6);
                float3 tMin = (boxMin - origin) * invDir;
                float3 tMax = (boxMax - origin) * invDir;
                float3 tNear = min(tMin, tMax);
                float3 tFar = max(tMin, tMax);
                float t0 = max(max(tNear.x, tNear.y), tNear.z);
                float t1 = min(min(tFar.x, tFar.y), tFar.z);
                return float2(t0, t1);
            }
            
            //P(cosθ) = (1 - g²) / [4π * (1 + g² - 2gcosθ)^(3/2)]
            //Use this phase function for anisotropic scattering if needed, currently not used in the shader
            float henyeyGreenstein(float cosTheta, float g) {
                float g2 = g * g;
                float denominator = 1.0 + g2 - 2.0 * g * cosTheta;
                return (1.0 - g2) / (4.0 * 3.14159265 * (denominator * sqrt(denominator)));
            }
            
            //I = I₀ * e^(-α * x)
            float beerLaw(float density, float absorption) {
                return exp(-density * absorption);
            }
            
            float powderEffect(float density, float cosTheta) {
                return 1.0 - exp(-density * 2.0 * (1.0 - cosTheta));
            }
            
            struct AppData {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };
            
            struct V2F {
                float4 pos : SV_POSITION;
                float3 worldPos : TEXCOORD0;
                float3 viewDir : TEXCOORD1;
                float4 screenPos : TEXCOORD2;
                SHADOW_COORDS(3)
                UNITY_FOG_COORDS(4)
            };

            V2F vert(AppData v) {
                V2F o;
                o.pos = UnityObjectToClipPos(v.vertex);
                o.worldPos = mul(unity_ObjectToWorld, v.vertex).xyz;
                o.viewDir = normalize(UnityWorldSpaceViewDir(o.worldPos));
                o.screenPos = ComputeScreenPos(o.pos);
                TRANSFER_SHADOW(o);
                UNITY_TRANSFER_FOG(o, o.pos);
                return o;
            }
            
            fixed4 frag(V2F i) : SV_Target {
                PrecomputeValues();
                float sceneDepth = LinearEyeDepth(tex2Dproj(_CameraDepthTexture, UNITY_PROJ_COORD(i.screenPos)));

                float2 screenCenter = float2(0.5, 0.5);
                float distFromCenter = distance(i.screenPos.xy / i.screenPos.w, screenCenter);
                
                float2 screenUV = i.screenPos.xy / i.screenPos.w;
                float2 scaledUV = floor(screenUV * _ScreenParams.xy) / (_ScreenParams.xy);
                
                Ray ray;
                ray.origin = _WorldSpaceCameraPos;
                ray.direction = normalize(i.worldPos - _WorldSpaceCameraPos);
                float3 volumeMin = float3(-_VolumeSize/2, _CloudMinHeight, -_VolumeSize/2);
                float3 volumeMax = float3(_VolumeSize/2, _CloudMaxHeight, _VolumeSize/2);
                
                float2 tValues = rayBoxIntersection(ray.origin, ray.direction, volumeMin, volumeMax);
                float t0 = tValues.x;
                float t1 = tValues.y;

                if (t0 >= t1 || t1 <= 0) {
                    return fixed4(_SkyColor.rgb, 0);
                }
                
                t0 = max(t0, 0);
                t1 = min(t1, t0 + _MaxDistance);
                
                if (t0 >= t1) {
                    return fixed4(_SkyColor.rgb, 0);
                }

                int steps = (int)_Steps;
                steps = (int)(steps);

                // Adaptive step count based on distance from center, Optional, uncomment to enable
                /*
                steps = (int)lerp(steps, steps * 0.5, saturate(distFromCenter * 1.0));
                lightSteps = (int)lerp(lightSteps, lightSteps * 0.5, saturate(distFromCenter * 1.0));
                */

                int lightSteps = (int)_LightSteps;
                lightSteps = (int)(lightSteps);
                
                float baseStepSize = (t1 - t0) / steps;
                float4 finalColor = float4(0, 0, 0, 0);
                float3 lightDir = normalize(_WorldSpaceLightPos0.xyz);
                float4 lightColor = _LightColor0;
                
                float phase = max(0.0, dot(ray.direction, lightDir));
                float silverLining = pow(saturate(dot(normalize(ray.direction + lightDir), lightDir)), _SilverLiningSpread) * _SilverLiningIntensity;
                phase += silverLining;

                //Alternative dither method using a hash, uncomment to use
                float frameIndex = fmod(_Time.y * 60.0, 8.0);
                float2 jitter = float2(frameIndex * 0.125, frameIndex * 0.125);
                float dither = frac(52.9829189 * frac(0.06711056 * (i.pos.x + jitter.x) + 0.00583715 * (i.pos.y + jitter.y)));

                //Alternative dither method using Sobol sequence, uncomment to use
                /*
                float frameIndex = fmod(_Time.y * 60.0, 512.0);
                uint2 pixelCoord = uint2(i.pos.xy);
                float dither = sobol2d(pixelCoord, uint(frameIndex));
                */

                //Alternative dither method using sin/cos, uncomment to use
                /*
                float dither = frac(sin(dot(scaledUV + jitter, float2(12.9898, 78.233))) * 43758.5453);
                */

                float distance = t0;
                float prevDensity = 0.0;

                for (int step = 0; step < steps; step++) {
                    if (distance > sceneDepth) break;
                    if (distance >= t1) break;
                    float3 currentPos = ray.origin + ray.direction * distance;
                    
                    float currentDensity = cloud_density(currentPos);
                    float density = lerp(currentDensity, (currentDensity + prevDensity) * 0.5, _StepSmoothing);
                    prevDensity = currentDensity;
                    float adaptiveStepSize = lerp(baseStepSize * 8.0, baseStepSize, saturate(density * 20.0));
                    if (step == 0) {
                        distance += dither * adaptiveStepSize;
                        currentPos = ray.origin + ray.direction * distance;
                    }

                    if (density > 0.01) {
                        float lightDensity = 0.0;
                        float3 lightPos = currentPos;
                        float lightStepSize = 96.0;
                        for (int lStep = 0; lStep < lightSteps; lStep++) {
                            lightPos += lightDir * lightStepSize;
                            if (any(lightPos < volumeMin) || any(lightPos > volumeMax)) break;
                            lightDensity += cloud_density(lightPos) * lightStepSize;
                        }
                        
                        float lightTransmission = beerLaw(lightDensity, _LightAbsorption * 0.5);
                        float shadow = SHADOW_ATTENUATION(i);
                        lightTransmission *= shadow;
                        
                        float powder = powderEffect(density, dot(ray.direction, lightDir));
                        float3 ambient = _AmbientColor.rgb * 0.3;
                        float3 sunLight = _SunColor.rgb * lightColor.rgb * phase * lightTransmission * 2.0;
                        sunLight *= powder;
                        sunLight *= _HDRExposure;
                        float3 cloudColor = lerp(ambient, sunLight, lightTransmission) * _CloudColor.rgb;
                        
                        float viewTransmission = beerLaw(density * adaptiveStepSize, _CloudAttenuation);
                        float alpha = (1.0 - viewTransmission);
                        
                        float4 src = float4(cloudColor, alpha);
                        finalColor = finalColor + src * (1.0 - finalColor.a);
                    }
                    
                    distance += adaptiveStepSize;
                    if (finalColor.a > 0.98) break;
                }
                
                float3 viewDir = normalize(i.worldPos - _WorldSpaceCameraPos);
                float horizonDot = dot(viewDir, float3(0, 1, 0));
                float horizonFade = smoothstep(0.0, 0.2, horizonDot);
                finalColor.a *= horizonFade;
                float distanceFadeVal = length(i.worldPos - _WorldSpaceCameraPos);
                float distanceFade = 1.0 - smoothstep(_VolumeSize * 0.8, _VolumeSize, distanceFadeVal);
                finalColor.a *= distanceFade;
                finalColor.rgb = lerp(_SkyColor.rgb, finalColor.rgb, finalColor.a);
                
                UNITY_APPLY_FOG(i.fogCoord, finalColor);
                return finalColor;
            }
            ENDCG
        }
    }
    FallBack "Transparent/VertexLit"
    CustomEditor "VolumetricCloudsEditor"
}