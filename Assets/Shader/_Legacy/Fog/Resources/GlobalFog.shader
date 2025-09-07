Shader "Hidden/GlobalFog"
{
    // Properties are now controlled entirely by the C# script,
    // so this block can be empty.
    Properties
    {
    }

    SubShader
    {
        Cull Off ZWrite Off ZTest Always

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            // This creates two shader variants. Unity will pick the right one based on
            // whether the "DIRECTIONAL_LIGHT_ON" keyword is enabled from the C# script.
            // This is more efficient than using an if-statement on a uniform.
            #pragma multi_compile __ DIRECTIONAL_LIGHT_ON

            #include "UnityCG.cginc"

            // Input structure for the vertex shader
            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            // Structure to pass data from vertex to fragment shader
            struct v2f
            {
                float4 pos : SV_POSITION;
                float2 uv : TEXCOORD0;
                // World space vector from camera to a point on the far clip plane
                float3 viewVector : TEXCOORD1;
            };

            // Texture samplers
            sampler2D _MainTex;
            sampler2D _CameraDepthTexture;
            float4 _MainTex_ST;

            // Fog Properties (set from C#)
            float4 _FogColor;
            float _FogIntensity;
            float _FogDensity;
            float _FogStart;
            float _FogHeightStart;
            float _FogHeightEnd;

            // Light Properties (set from C#)
            float4 _LightColor;
            float3 _LightDir;
            float _SunGlowIntensity;

            v2f vert(appdata v)
            {
                v2f o;
                o.pos = UnityObjectToClipPos(v.vertex);
                o.uv = TRANSFORM_TEX(v.uv, _MainTex);
                
                // Calculate the world space vector from the camera to the far clip plane.
                // This will be used in the fragment shader to reconstruct the world position of each pixel.
                o.viewVector = mul(unity_CameraInvProjection, float4(v.uv * 2 - 1, 0, -1)).xyz;
                o.viewVector = mul(unity_CameraToWorld, float4(o.viewVector, 0)).xyz;

                return o;
            }

            half4 frag(v2f i) : SV_Target
            {
                // Sample the original scene color
                half4 sceneColor = tex2D(_MainTex, i.uv);
                
                // Reconstruct the pixel's world position using the depth texture
                float depth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, i.uv);
                float linearDepth = LinearEyeDepth(depth);
                float3 worldPos = _WorldSpaceCameraPos + linearDepth * normalize(i.viewVector);
                
                // --- FOG AMOUNT CALCULATION ---
                // 1. Distance-based fog
                float fogDistance = max(0, linearDepth - _FogStart);
                // Using squared distance makes the fog appear denser more quickly
                float distanceFog = 1.0 - exp(-_FogDensity * fogDistance * fogDistance);
                
                // 2. Height-based fog
                float heightFactor = saturate((worldPos.y - _FogHeightStart) / (_FogHeightEnd - _FogHeightStart));
                float heightFog = exp(-heightFactor * 4.0);
                
                // 3. Combine fog types and apply overall intensity
                float fogFactor = saturate(distanceFog * heightFog) * _FogIntensity;
                
                // --- FOG COLOR CALCULATION ---
                // Start with the base fog color
                half3 finalFogColor = _FogColor.rgb;

                // If the lighting keyword is on, calculate light scattering
                #if DIRECTIONAL_LIGHT_ON
                // Calculate the direction from the pixel to the camera
                float3 viewDir = normalize(worldPos - _WorldSpaceCameraPos);
                // The light direction is passed in from the C# script
                float3 lightDir = normalize(_LightDir);

                // Calculate the dot product between view and light directions.
                // This value is highest when looking directly at the light source.
                float scatter = saturate(dot(viewDir, lightDir));
                
                // Use pow() to create a tight, bright spot for the sun glow.
                // A higher exponent creates a smaller, more focused glow.
                float sunGlow = pow(scatter, 32.0);

                // Add the light's color to the fog, modulated by the glow effect and its intensity.
                // This makes the fog itself appear to be illuminated.
                finalFogColor += _LightColor.rgb * sunGlow * _SunGlowIntensity;
                #endif

                // --- FINAL BLENDING ---
                // Linearly interpolate between the original scene color and the calculated fog color
                half3 finalColor = lerp(sceneColor.rgb, finalFogColor, fogFactor);
                
                return half4(finalColor, sceneColor.a);
            }
            ENDCG
        }
    }
    Fallback Off
}
