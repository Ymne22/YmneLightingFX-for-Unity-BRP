Shader "Hidden/VoxelLightShader"
{
    Properties { }
    SubShader
    {
        Tags { "Queue"="Transparent" "RenderType"="Transparent" "IgnoreProjector"="True" }
        LOD 100

        Pass
        {
            Blend One One 
            Cull Front
            ZWrite Off
            ZTest Always 

            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 3.0
            
            #pragma multi_compile __ NOISE_ENABLED
            #pragma multi_compile __ SMOOTH_VOXELS

            #include "UnityCG.cginc"

            // --- Simplex Noise (Used only for FBM when enabled) ---
            float3 mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
            float4 mod289(float4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
            float4 permute(float4 x) { return mod289(((x*34.0)+1.0)*x); }
            float4 taylorInvSqrt(float4 r) { return 1.79284291400159 - 0.85373472095314 * r; }
            float snoise(float3 v){const float2 C = float2(1.0/6.0, 1.0/3.0) ;const float4 D = float4(0.0, 0.5, 1.0, 2.0);float3 i  = floor(v + dot(v, C.yyy) );float3 x0 = v - i + dot(i, C.xxx) ;float3 g = step(x0.yzx, x0.xyz); float3 l = 1.0 - g;float3 i1 = min( g.xyz, l.zxy ); float3 i2 = max( g.xyz, l.zxy );float3 x1 = x0 - i1 + C.xxx;float3 x2 = x0 - i2 + C.yyy; float3 x3 = x0 - D.yyy;i = mod289(i);float4 p = permute( permute( permute( i.z + float4(0.0, i1.z, i2.z, 1.0 )) + i.y + float4(0.0, i1.y, i2.y, 1.0 )) + i.x + float4(0.0, i1.x, i2.x, 1.0 ));float n_ = 0.142857142857;float3 ns = n_ * D.wyz - D.xzx;float4 j = p - 49.0 * floor(p * ns.z * ns.z);float4 x_ = floor(j * ns.z); float4 y_ = floor(j - 7.0 * x_ );float4 x = x_ * ns.x + ns.yyyy;float4 y = y_ * ns.x + ns.yyyy; float4 h = 1.0 - abs(x) - abs(y);float4 b0 = float4( x.xy, y.xy );float4 b1 = float4( x.zw, y.zw );float4 s0 = floor(b0)*2.0 + 1.0; float4 s1 = floor(b1)*2.0 + 1.0;float4 sh = -step(h, float4(0,0,0,0));float4 a0 = b0.xzyw + s0.xzyw*sh.xxyy ;float4 a1 = b1.xzyw + s1.xzyw*sh.zzww ;float3 p0 = float3(a0.xy,h.x); float3 p1 = float3(a0.zw,h.y); float3 p2 = float3(a1.xy,h.z);float3 p3 = float3(a1.zw,h.w);float4 norm = taylorInvSqrt(float4(dot(p0,p0), dot(p1,p1), dot(p2,p2), dot(p3,p3)));p0 *= norm.x; p1 *= norm.y; p2 *= norm.z;p3 *= norm.w;float4 m = max(0.6 - float4(dot(x0,x0), dot(x1,x1), dot(x2,x2), dot(x3,x3)), 0.0);m = m * m;return 42.0 * dot( m*m, float4( dot(p0,x0), dot(p1,x1), dot(p2,x2), dot(p3,x3) ) );}

            // --- Fractional Brownian Motion (FBM) (Used only when enabled) ---
            float fbm(float3 p, int octaves)
            {
                float value = 0.0;
                float amplitude = 0.5;
                float frequency = 1.0;
                for (int i = 0; i < octaves; i++)
                {
                    value += amplitude * snoise(p * frequency);
                    amplitude *= 0.5;
                    frequency *= 2.0;
                }
                return value * 0.5 + 0.5;
            }

            struct v2f
            {
                float4 vertex : SV_POSITION;
                float3 worldPos : TEXCOORD0;
                float4 screenPos : TEXCOORD1;
            };

            sampler3D _VoxelTexture;
            sampler2D _CameraDepthTexture;
            
            float4 _LightColor;
            float4 _GridParams;
            float4 _ProximityParams;
            float4 _AnisotropyParams;
            float3 _NoiseScale;
            float3 _NoiseVelocity;
            float _NoiseIntensity;
            float3 _GridCenter;
            int _RaymarchSteps;
            int _NoiseOctaves;
            float _VoxelTextureRes;
            
            v2f vert (appdata_base v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.worldPos = mul(unity_ObjectToWorld, v.vertex).xyz;
                o.screenPos = ComputeScreenPos(o.vertex);
                return o;
            }

            bool IntersectAABB(float3 rayOrigin, float3 rayDir, float3 boxMin, float3 boxMax, out float tmin, out float tmax)
            {
                float3 invDir = 1.0 / rayDir;
                float3 t0s = (boxMin - rayOrigin) * invDir;
                float3 t1s = (boxMax - rayOrigin) * invDir;
                float3 tsmaller = min(t0s, t1s);
                float3 tbigger = max(t0s, t1s);
                tmin = max(0, max(tsmaller.x, max(tsmaller.y, tsmaller.z)));
                tmax = min(tbigger.x, min(tbigger.y, tbigger.z));
                return tmin < tmax;
            }

            // Henyey-Greenstein
            float PhaseHG(float cosTheta, float g)
            {
                float g2 = g * g;
                return (1.0 - g2) / (4.0 * 3.14159265 * pow(1.0 + g2 - 2.0 * g * cosTheta, 1.5));
            }

            // Trilinear interpolation
            float sampleVoxelsSmooth(sampler3D tex, float3 uvw, float res)
            {
                float3 texelSize = 1.0 / res;
                
                // Calculate integer and fractional parts
                float3 coord = uvw * res - 0.5;
                float3 i = floor(coord);
                float3 f = frac(coord);
                
                // Clamp to avoid sampling outside the texture
                i = clamp(i, 0, res - 1);
                
                // Sample the 8 surrounding texels
                float c000 = tex3D(tex, (i + float3(0, 0, 0) + 0.5) * texelSize).r;
                float c001 = tex3D(tex, (i + float3(0, 0, 1) + 0.5) * texelSize).r;
                float c010 = tex3D(tex, (i + float3(0, 1, 0) + 0.5) * texelSize).r;
                float c011 = tex3D(tex, (i + float3(0, 1, 1) + 0.5) * texelSize).r;
                float c100 = tex3D(tex, (i + float3(1, 0, 0) + 0.5) * texelSize).r;
                float c101 = tex3D(tex, (i + float3(1, 0, 1) + 0.5) * texelSize).r;
                float c110 = tex3D(tex, (i + float3(1, 1, 0) + 0.5) * texelSize).r;
                float c111 = tex3D(tex, (i + float3(1, 1, 1) + 0.5) * texelSize).r;
                
                // Trilinear interpolation
                float c00 = lerp(c000, c100, f.x);
                float c01 = lerp(c001, c101, f.x);
                float c10 = lerp(c010, c110, f.x);
                float c11 = lerp(c011, c111, f.x);
                
                float c0 = lerp(c00, c10, f.y);
                float c1 = lerp(c01, c11, f.y);
                
                return lerp(c0, c1, f.z);
            }

            fixed4 frag (v2f i) : SV_Target
            {
                float3 rayOrigin = _WorldSpaceCameraPos;
                float3 rayDir = normalize(i.worldPos - rayOrigin);

                float3 boxMin = _GridCenter - _GridParams.x * 0.5;
                float3 boxMax = _GridCenter + _GridParams.x * 0.5;
                float tmin, tmax;
                
                if (!IntersectAABB(rayOrigin, rayDir, boxMin, boxMax, tmin, tmax))
                {
                    discard;
                }
                
                float2 screenUV = i.screenPos.xy / i.screenPos.w;
                float sceneDepthRaw = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, screenUV);
                float sceneDepth = LinearEyeDepth(SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, screenUV));
                
                tmax = min(tmax, sceneDepth);
                if (tmin >= tmax) discard;

                float rayLength = tmax - tmin;
                float stepSize = rayLength / (float)_RaymarchSteps;
                
                float3 accumulatedColor = float3(0, 0, 0);
                float transmittance = 1.0;
                float frameIndex = fmod(_Time.y * 60.0, 8.0);
                float2 jitter = float2(frameIndex * 0.125, frameIndex * 0.125);
                float jitterOffset = stepSize * (frac(sin(dot(i.screenPos.xy + jitter, float2(12.9898, 78.233))) * 43758.5453));
                
                // Calculate light direction for anisotropy
                float3 lightDir = normalize(_GridCenter - rayOrigin);
                
                [loop]
                for (int s = 0; s < _RaymarchSteps; s++)
                {
                    float currentRayDist = tmin + jitterOffset + s * stepSize;
                    if (currentRayDist > tmax) break;

                    float3 currentPos = rayOrigin + rayDir * currentRayDist;
                    float3 uvw = (currentPos - _GridCenter) / _GridParams.x + 0.5;
                    
                    // Sample voxels with or without smoothing
                    #if SMOOTH_VOXELS
                        float voxelDensity = sampleVoxelsSmooth(_VoxelTexture, saturate(uvw), _VoxelTextureRes);
                    #else
                        float voxelDensity = tex3D(_VoxelTexture, saturate(uvw)).r;
                    #endif
                    
                    float finalDensity = voxelDensity;

                    // This block is now compiled out if enableNoise is false
                    #if NOISE_ENABLED
                        float noise = fbm(currentPos * _NoiseScale + _Time.y * _NoiseVelocity, _NoiseOctaves);
                        finalDensity = lerp(voxelDensity, voxelDensity * noise, _NoiseIntensity);
                    #endif

                    if (finalDensity > 0.01)
                    {
                        float lightRadius = _GridParams.x * 0.5;
                        float distToLight = distance(currentPos, _GridCenter);
                        float distFactor = 1.0 - saturate(distToLight / lightRadius); 
                        float proximityMultiplier = 1.0 + _ProximityParams.x * pow(distFactor, _ProximityParams.y);
                        
                        // Calculate anisotropic scattering
                        float3 toLight = normalize(_GridCenter - currentPos);
                        float cosTheta = dot(rayDir, toLight);
                        float phase = PhaseHG(cosTheta, _AnisotropyParams.x);
                        phase = pow(phase, _AnisotropyParams.y);
                        
                        float3 inScattering = _LightColor.rgb * finalDensity * _GridParams.y * proximityMultiplier * phase;
                        
                        accumulatedColor += inScattering * transmittance * stepSize;

                        float extinction = finalDensity * _GridParams.y + _GridParams.z;
                        transmittance *= exp(-extinction * stepSize);
                    }
                    
                    if (transmittance < 0.01)
                        break;
                }

                return float4(accumulatedColor, 1.0);
            }
            ENDCG
        }
    }
}