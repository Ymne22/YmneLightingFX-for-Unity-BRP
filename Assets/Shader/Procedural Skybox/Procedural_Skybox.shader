Shader "Skybox/Physically-Based Procedural"
{
    Properties
    {
        [Header(Planet Settings)]
        _GroundColor("Ground Color", Color) = (0.369, 0.349, 0.341, 1)
        _PlanetRadius("Planet Radius (km)", Float) = 6371.0
        _AtmosphereRadius("Atmosphere Radius (km)", Float) = 6471.0

        [Header(Sun Settings)]
        _SunIntensity ("Sun Intensity", Float) = 256.0
        _SunSize ("Sun Size", Range(0.0, 0.1)) = 0.000025

        [Header(Color and Fog Settings)]
        _SkyTint("Sky Tint (Day)", Color) = (1, 1, 1, 1)
        _SunsetTint("Sunset Tint", Color) = (0.4528301, 0.1599549, 0.3, 1)
        _HorizonColor("Horizon Color", Color) = (1, 0.8, 0.6, 1)
        _FogDensity("Atmosphere Density", Range(0, 100)) = 1.0
        
        [Header(Horizon Fog)]
        _FogColor("Fog Color", Color) = (0.1935742, 0.2302319, 0.2830189, 1)
        _FogStart("Fog Start Height", Range(-1.0, 1.0)) = -1.0
        _FogEnd("Fog End Height", Range(-1.0, 1.0)) = 0.35
        _FogIntensity("Fog Intensity", Range(0, 100)) = 32.0
        
        [Header(Night Settings)]
        [NoScaleOffset] _MoonTex ("Moon Texture", 2D) = "white" {}
        _MoonSize("Moon Size", Range(0.0, 0.1)) = 0.0374
        _MoonIntensity ("Moon Intensity", Float) = 8.0
        _NightAmbientColor ("Night Ambient Color", Color) = (0.04999997, 0.07999995, 0.1499999, 1)
        _MinGroundAmbient("Minimum Ground Ambient", Range(0, 0.1)) = 0.01

        [Header(Stars Settings)]
        _StarsIntensity("Stars Intensity", Range(0, 5)) = 1.5
        _StarsDensity("Stars Density", Range(0.9, 0.999)) = 0.9
        _StarsScale("Stars Scale", Range(50, 500)) = 128.0
        _StarsTwinkleSpeed("Stars Twinkle Speed", Range(0, 10)) = 0.25

        [Header(Clouds Settings)]
        [NoScaleOffset] _CloudMap("Cloud Map (Grayscale)", 2D) = "white" {}
        _CloudColor("Cloud Color", Color) = (1,1,1,1)
        _CloudTiling("Cloud Tiling", Float) = 0.35
        _CloudSpeed("Cloud Speed", Float) = -0.01
        _CloudRotationSpeed("Cloud Rotation Speed", Float) = 0.01
        _CloudCover("Cloud Cover", Range(0, 1)) = 0.9
        _CloudOpacity("Cloud Opacity", Range(0, 1)) = 0.25
        _CloudExtinction("Cloud Extinction", Range(0.1, 5.0)) = 1.5
        _CloudScattering("Cloud Scattering", Range(0, 20.0)) = 1.0
        _CloudAnisotropy("Cloud Anisotropy (g)", Range(-0.9, 0.9)) = 0.1

        [Header(Day Night Transition)]
        _SunFadeStartAngle("Sun Fade Start Angle", Range(0.0, 90.0)) = 5.0
        _SunFadeEndAngle("Sun Fade End Angle", Range(-90.0, 0.0)) = -2.0
        [Toggle] _InvertDayNight ("Invert Day/Night?", Float) = 0

        [Header(Scattering Coefficients)]
        _BetaR ("Rayleigh Scattering Coefficient", Vector) = (0.0000058, 0.0000135, 0.0000331, 0)
        _MieCoefficient ("Mie Coefficient", Float) = 0.00001 
        
        [Header(Atmosphere Density)]
        _RayleighScaleHeight ("Rayleigh Scale Height (km)", Float) = 128.0
        _MieScaleHeight ("Mie Scale Height (km)", Float) = 1.5
        _MieG ("Mie Anisotropy (g)", Range(-0.99, 0.99)) = 0.99

        [Header(Performance and Quality)]
        _SampleCount("View Samples", Range(1, 32)) = 2
        _Exposure("Exposure", Range(0.1, 5.0)) = 1.0
    }
    SubShader
    {
        Tags { "Queue"="Background" "RenderType"="Background" "PreviewType"="Skybox" }
        Cull Off ZWrite Off

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 3.0

            #include "UnityCG.cginc"

            #define LIGHT_SAMPLE_COUNT 8
            #define PI 3.14159265359

            // Global properties
            float _SunIntensity, _SunSize, _PlanetRadius, _AtmosphereRadius, _FogDensity, _MinGroundAmbient;
            float _MoonIntensity, _MoonSize, _MieCoefficient, _RayleighScaleHeight, _MieScaleHeight, _MieG, _Exposure;
            float _SunFadeStartAngle, _SunFadeEndAngle, _InvertDayNight;
            int _SampleCount;
            fixed4 _GroundColor;
            half4 _SkyTint, _SunsetTint, _HorizonColor, _NightAmbientColor;
            sampler2D _MoonTex;
            float3 _BetaR;

            half4 _FogColor;
            float _FogStart, _FogEnd, _FogIntensity;

            float _StarsIntensity, _StarsDensity, _StarsScale, _StarsTwinkleSpeed;
            
            sampler2D _CloudMap;
            half4 _CloudColor;
            float _CloudTiling, _CloudSpeed, _CloudRotationSpeed, _CloudCover, _CloudOpacity, _CloudExtinction, _CloudScattering, _CloudAnisotropy;

            struct v2f
            {
                float4 pos : SV_POSITION;
                float3 worldPos : TEXCOORD0;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            v2f vert(appdata_base v)
            {
                v2f o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                o.pos = UnityObjectToClipPos(v.vertex);
                o.worldPos = v.vertex.xyz;
                return o;
            }

            // --- Core Functions ---

            float3 hash3(float3 p)
            {
                p = float3(dot(p, float3(127.1, 311.7, 74.7)),
                           dot(p, float3(269.5, 183.3, 246.1)),
                           dot(p, float3(113.5, 271.9, 124.6)));
                return frac(sin(p) * 43758.5453123);
            }

            float2 raySphereIntersect(float3 rayOrigin, float3 rayDir, float3 sphereCenter, float radius)
            {
                float3 oc = rayOrigin - sphereCenter;
                float b = dot(oc, rayDir);
                float c = dot(oc, oc) - radius * radius;
                float h = b * b - c;
                if (h < 0.0) return float2(-1.0, -1.0);
                h = sqrt(h);
                return float2(-b - h, -b + h);
            }

            float getOpticalDepth(float3 rayOrigin, float3 rayDir, float length, float scaleHeight)
            {
                float opticalDepth = 0.0;
                float segmentLength = length / (float)LIGHT_SAMPLE_COUNT;
                for (int i = 0; i < LIGHT_SAMPLE_COUNT; i++)
                {
                    float3 samplePos = rayOrigin + rayDir * ((float)i + 0.5) * segmentLength;
                    float height = distance(samplePos, float3(0,0,0)) - _PlanetRadius;
                    if (height < 0) return 1e10;
                    opticalDepth += exp(-height / scaleHeight);
                }
                return opticalDepth * segmentLength;
            }
            
            float rayleighPhase(float cosTheta) { return (3.0 / (16.0 * PI)) * (1.0 + cosTheta * cosTheta); }
            float henyeyGreensteinPhase(float cosTheta, float g) {
                float g2 = g * g;
                return (1.0 / (4.0 * PI)) * ((1.0 - g2) / pow(1.0 + g2 - 2.0 * g * cosTheta, 1.5));
            }

            half3 calculateScattering(float3 lightDir, float lightIntensity, float3 viewDir, float3 cameraPos, float rayLength, float3 betaR, float betaM)
            {
                half3 totalRayleigh = 0;
                half3 totalMie = 0;
                float segmentLength = rayLength / (float)_SampleCount;

                for (int j = 0; j < _SampleCount; j++)
                {
                    float3 samplePos = cameraPos + viewDir * (float(j) + 0.5) * segmentLength;
                    float height = distance(samplePos, float3(0,0,0)) - _PlanetRadius;
                    if (height < 0.0) continue;

                    float opticalDepthViewR = getOpticalDepth(cameraPos, viewDir, distance(cameraPos, samplePos), _RayleighScaleHeight);
                    float opticalDepthViewM = getOpticalDepth(cameraPos, viewDir, distance(cameraPos, samplePos), _MieScaleHeight);
                    float2 lightIntersection = raySphereIntersect(samplePos, lightDir, float3(0,0,0), _AtmosphereRadius);
                    
                    if(lightIntersection.y > 0.0) {
                        float opticalDepthLightR = getOpticalDepth(samplePos, lightDir, lightIntersection.y, _RayleighScaleHeight);
                        float opticalDepthLightM = getOpticalDepth(samplePos, lightDir, lightIntersection.y, _MieScaleHeight);
                        float3 transmittance = exp(-( (opticalDepthLightR + opticalDepthViewR) * betaR + (opticalDepthLightM + opticalDepthViewM) * betaM ));
                        float cosTheta = dot(viewDir, lightDir);
                        totalRayleigh += transmittance * rayleighPhase(cosTheta) * exp(-height / _RayleighScaleHeight);
                        totalMie += transmittance * henyeyGreensteinPhase(cosTheta, _MieG) * exp(-height / _MieScaleHeight);
                    }
                }
                return (totalRayleigh * betaR + totalMie * betaM) * lightIntensity * segmentLength;
            }


            // --- Main Fragment Shader ---
            half4 frag(v2f i) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                // --- Setup ---
                float3 sunDir = normalize(_WorldSpaceLightPos0.xyz);
                float3 moonDir = -sunDir;
                float3 viewDir = normalize(i.worldPos);
                float3 cameraPos = float3(0, _PlanetRadius + 0.001, 0);
                float sunAngle = sunDir.y;
                
                float startSin = sin(radians(_SunFadeStartAngle));
                float endSin = sin(radians(_SunFadeEndAngle));
                float sunlightFactor = saturate(smoothstep(endSin, startSin, sunAngle));

                // --- Invert Day/Night if toggled ---
                if (_InvertDayNight > 0.5) {
                    sunlightFactor = 1.0 - sunlightFactor;
                }

                // --- Planet Intersection Check ---
                float2 planetIntersection = raySphereIntersect(cameraPos, viewDir, float3(0,0,0), _PlanetRadius);
                if (planetIntersection.x > 0)
                {
                    float3 dayAmbient = lerp(_HorizonColor.rgb, float3(1,1,1), saturate(sunAngle * 2.0)) * _SunIntensity * 0.01;
                    float3 nightAmbient = _NightAmbientColor.rgb * _MoonIntensity * 0.5;
                    float3 finalAmbient = lerp(nightAmbient, dayAmbient, sunlightFactor) + _MinGroundAmbient;
                    
                    half3 finalGroundColor = _GroundColor.rgb * finalAmbient;
                    finalGroundColor *= _Exposure;
                    return half4(finalGroundColor, 1.0);
                }

                // --- Sky Calculation ---
                float2 atmosphereIntersection = raySphereIntersect(cameraPos, viewDir, float3(0,0,0), _AtmosphereRadius);
                if (atmosphereIntersection.y < 0.0) {
                     return half4(_NightAmbientColor.rgb * _Exposure, 1.0);
                }
                float rayLength = atmosphereIntersection.y;
                float mieCoefficient = _MieCoefficient * _FogDensity;

                float sunsetFactor = smoothstep(0.2, 0.0, sunAngle);
                float3 scatterWavelengths = lerp(float3(1, 1, 1), float3(1.2, 0.55, 0.25), sunsetFactor);
                float3 dynamicBetaR = _BetaR * scatterWavelengths;
                
                half3 dayScattering = calculateScattering(sunDir, _SunIntensity, viewDir, cameraPos, rayLength, dynamicBetaR, mieCoefficient);
                half3 nightScattering = calculateScattering(moonDir, _MoonIntensity, viewDir, cameraPos, rayLength, _BetaR, mieCoefficient);
                
                float horizonFactor = pow(saturate(1.0 - viewDir.y), 8.0);
                float sunProximity = saturate(dot(viewDir, sunDir) * 0.5 + 0.5);
                float glowMask = horizonFactor * pow(sunProximity, 16.0);
                float3 glowColor = lerp(_HorizonColor.rgb, _SunsetTint.rgb, pow(sunProximity, 4.0));
                dayScattering += glowColor * glowMask * _SunIntensity * sunsetFactor * 0.08;
                dayScattering *= _SkyTint.rgb;

                half3 skyColor = lerp(nightScattering + _NightAmbientColor.rgb, dayScattering, sunlightFactor);

                // --- STABLE STARS CALCULATION ---
                half3 starsColor = 0;
                if (sunlightFactor < 0.8)
                {
                    float3 cell_id = floor(viewDir * _StarsScale);
                    float3 cell_hash = hash3(cell_id);
                    if (cell_hash.x > _StarsDensity)
                    {
                        float2 star_pos_offset = cell_hash.yz - 0.5;
                        float3 p = (viewDir * _StarsScale) - (cell_id + float3(star_pos_offset.x, star_pos_offset.y, 0.0) + 0.5);
                        float dist_sq = dot(p, p);
                        float star_falloff = exp(-40.0 * dist_sq);
                        if (star_falloff > 0.01)
                        {
                            float3 star_props = hash3(cell_id + 1.0);
                            float twinkle = 0.5 + 0.5 * sin((star_props.x + _Time.y * _StarsTwinkleSpeed) * 5.0);
                            float brightness = (0.5 + 0.5 * star_props.y) * star_falloff;
                            starsColor = half3(1.0, 1.0, 1.0) * brightness * twinkle * _StarsIntensity;
                        }
                    }
                }
                skyColor += starsColor * (1.0 - saturate(sunlightFactor * 2.0));
                
                // --- Calculate Sun Disc Color ---
                float3 sunColor = 0;
                float sunDot = dot(viewDir, sunDir);
                float sunDisc = smoothstep(1.0 - _SunSize, 1.0, sunDot);
                if (sunDisc > 0)
                {
                    float2 sunIntersection = raySphereIntersect(cameraPos, sunDir, float3(0,0,0), _AtmosphereRadius);
                    float sunOpticalDepthR = getOpticalDepth(cameraPos, sunDir, sunIntersection.y, _RayleighScaleHeight);
                    float sunOpticalDepthM = getOpticalDepth(cameraPos, sunDir, sunIntersection.y, _MieScaleHeight);
                    float3 sunExtinction = exp(-(sunOpticalDepthR * dynamicBetaR + sunOpticalDepthM * mieCoefficient));
                    float3 sunFinalColor = lerp(float3(1.0, 0.95, 0.9), _SunsetTint.rgb, sunsetFactor);
                    sunColor = sunDisc * sunExtinction * sunFinalColor * _SunIntensity * 0.5;
                }

                // --- Calculate Moon Disc Color ---
                float3 moonColor = 0;
                if (dot(viewDir, moonDir) > 0)
                {
                    float moonRadius = _MoonSize;
                    float3 moonPlaneVec = viewDir - moonDir * dot(viewDir, moonDir);
                    float distSq = dot(moonPlaneVec, moonPlaneVec);
                    if (distSq < moonRadius * moonRadius)
                    {
                        float3 moonUp = normalize(abs(moonDir.y) < 0.99 ? float3(0,1,0) : float3(1,0,0));
                        float3 moonRight = normalize(cross(moonDir, moonUp));
                        moonUp = cross(moonRight, moonDir);
                        float u = dot(moonPlaneVec, moonRight) / moonRadius;
                        float v = dot(moonPlaneVec, moonUp) / moonRadius;
                        float2 moonUV = float2(u, v) * 0.5 + 0.5;
                        moonColor = tex2D(_MoonTex, moonUV).rgb * _MoonIntensity;
                    }
                }
                
                // --- Combine Sky and Celestial Bodies ---
                half3 bodyColor = lerp(moonColor, sunColor, sunlightFactor);
                half3 skyAndCelestials = skyColor + bodyColor;

                // --- CLOUDS CALCULATION (REALISTIC LIGHTING) ---
                half3 cloudFinalColor = 0;
                
                // --- Dome Rotation ---
                float rotationAngle = _Time.y * _CloudRotationSpeed;
                float s = sin(rotationAngle);
                float c = cos(rotationAngle);
                float2x2 rotationMatrix = float2x2(c, -s, s, c);
                float3 rotatedViewDir = viewDir;
                rotatedViewDir.xz = mul(rotationMatrix, viewDir.xz);

                // --- Triplanar Mapping for Clouds ---
                // The view direction acts as the position and normal on the sky sphere
                float3 blendWeights = abs(rotatedViewDir);
                // Sharpen the blend weights and re-normalize
                blendWeights = pow(blendWeights, 1);
                blendWeights /= (blendWeights.x + blendWeights.y + blendWeights.z);

                // Calculate UVs for each plane, including tiling and speed
                float2 timeOffset = float2(_Time.y * _CloudSpeed, 0);
                float2 uvX = rotatedViewDir.zy * _CloudTiling + timeOffset;
                float2 uvY = rotatedViewDir.xz * _CloudTiling + timeOffset;
                float2 uvZ = rotatedViewDir.xy * _CloudTiling + timeOffset;
                
                // Sample the cloud map from three directions
                float sampleX = tex2D(_CloudMap, uvX).r;
                float sampleY = tex2D(_CloudMap, uvY).r;
                float sampleZ = tex2D(_CloudMap, uvZ).r;

                // Blend the samples using the calculated weights
                float cloudSample = sampleX * blendWeights.x + sampleY * blendWeights.y + sampleZ * blendWeights.z;
                // --- End Triplanar Mapping ---

                float cloudCoverage = smoothstep(1.0 - _CloudCover, 1.0, cloudSample);

                if (cloudCoverage > 0.01)
                {
                    // Determine light direction (sun or moon)
                    float3 lightDir = lerp(moonDir, sunDir, sunlightFactor);

                    // Calculate ambient light for the cloud
                    half3 ambient = lerp(nightScattering + _NightAmbientColor.rgb * 0.2, dayScattering, sunlightFactor);
                    half3 cloudBaseColor = _CloudColor.rgb * ambient;

                    // Calculate direct light color
                    half3 directLightColorDay = lerp(float3(1.0, 0.95, 0.9), _SunsetTint.rgb, sunsetFactor) * _SunIntensity * 0.05;
                    half3 directLightColorNight = _NightAmbientColor.rgb * _MoonIntensity * 0.5;
                    half3 directLightColor = lerp(directLightColorNight, directLightColorDay, sunlightFactor);
                    
                    // Use phase function for realistic light scattering through clouds
                    float cosTheta = dot(viewDir, lightDir);
                    float cloudPhase = henyeyGreensteinPhase(cosTheta, _CloudAnisotropy);
                    
                    // Combine lighting
                    cloudFinalColor = cloudBaseColor * _CloudExtinction + directLightColor * cloudPhase * _CloudScattering;
                }

                // Blend clouds on top of the sky
                float finalCloudAlpha = cloudCoverage * _CloudOpacity * saturate(1.0 - viewDir.y);
                half3 skyWithClouds = lerp(skyAndCelestials, cloudFinalColor, finalCloudAlpha);
                
                // --- FOG CALCULATION ---
                float fogFactor = smoothstep(_FogStart, _FogEnd, viewDir.y);
                half3 dayFogColor = dayScattering * _FogColor.rgb;
                half3 nightFogColor = (nightScattering + _NightAmbientColor.rgb) * _FogColor.rgb;
                half3 fogColor = lerp(nightFogColor, dayFogColor, sunlightFactor);
                half3 finalColor = lerp(skyWithClouds, fogColor * _FogIntensity, 1.0 - fogFactor);
                // ---------------------------

                finalColor *= _Exposure;

                return half4(finalColor, 1.0);
            }
            ENDCG
        }
    }
    FallBack "Skybox/Cubemap"
}
