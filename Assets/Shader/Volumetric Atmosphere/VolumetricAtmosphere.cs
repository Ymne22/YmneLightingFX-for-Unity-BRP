#if UNITY_EDITOR
using UnityEditor;
#endif

using UnityEngine;
using UnityEngine.Rendering;
using System.Collections.Generic;

[ExecuteInEditMode]
[AddComponentMenu("Image Effects/Rendering/Volumetric Atmosphere (Clouds and Fog)")]
public class VolumetricAtmosphere : MonoBehaviour
{
    // Private class to hold data per camera
    private class CameraData
    {
        public CommandBuffer commandBuffer;
        public Material materialInstance;
        public Matrix4x4 prevViewProjMatrix;
        public RenderTexture historyTexture;
        public RenderTexture historyGodRayTexture;

        public void Release()
        {
            if (commandBuffer != null) commandBuffer.Release();
            if (historyTexture != null) Object.DestroyImmediate(historyTexture);
            if (historyGodRayTexture != null) Object.DestroyImmediate(historyGodRayTexture);
            if (materialInstance != null) Object.DestroyImmediate(materialInstance);
        }
    }

    private Shader _atmosphereShader;
    private Dictionary<Camera, CameraData> _cameraData = new Dictionary<Camera, CameraData>();

    [Header("General Settings")]
    public bool enableClouds = true;
    public bool enableFog = true;
    public bool enableGodRays = true;
    [Tooltip("The main directional light (Sun/Moon). Will be auto-detected if not assigned.")]
    public Light directionalLight;

    [Header("Temporal Reprojection")]
    public bool useTemporalReprojection = true;
    [Range(0.0f, 1.0f)] public float temporalBlendFactor = 0.95f;

    [Header("Quality & Performance")]
    [Range(0.1f, 1.0f)] public float resolutionScale = 0.5f;
    [Range(1, 128)] public int steps = 24;
    [Range(0, 8)] public int lightSteps = 1;
    [Range(0, 8)] public int filterIterations = 1;
    [Range(0.0f, 2.0f)] public float filterRadius = 1.0f;
    [Range(0.0f, 50.0f)] public float depthWeight = 0.05f;
    [Range(0.0f, 100.0f)] public float normalWeight = 0.1f;

    [Header("Cloud Shape & Coverage")]
    public float cloudMinHeight = 128f;
    public float cloudMaxHeight = 1024f;
    public Vector3 noiseSeedOffset = new Vector3(-5600, 1200, 1800);
    [Range(0.1f, 10f)] public float noiseScale = 0.5f;
    [Range(0f, 1f)] public float coverage = 0.5f;
    [Range(0.0f, 1f)] public float density = 0.1f;
    [Range(0.1f, 2f)] public float softness = 1.0f;
    [Range(0.1f, 5f)] public float curliness = 5.0f;
    [Range(0f, 1f)] public float detailIntensity = 0.25f;
    [Range(1f, 128f)] public float detailNoiseScale = 32.0f;

    [Header("Wind Animation")]
    public Vector3 windDirection = new Vector3(-1, 0, 1);
    public float windSpeed = 2f;
    public float cloudMorphSpeed = 0.005f;

    [Header("Cloud Lighting & Color")]
    [Range(0.1f, 3f)] public float lightAbsorption = 1.5f;
    [Range(0.1f, 3f)] public float selfShadowStrength = 2.0f;
    public Color cloudColor = Color.white;
    public Color sunColor = Color.white;
    public Color skyColor = Color.black;
    [Range(0f, 2f)] public float silverLiningIntensity = 2.0f;
    [Range(0f, 1f)] public float silverLiningSpread = 0.5f;

    [Header("Cloud Distance & Curvature")]
    public bool useDistanceFade = true;
    public float fadeStartDistance = 0f;
    public float fadeEndDistance = 8192f;
    public bool useCurvature = true;
    public float planetRadius = 6371000f;

    [Header("Global Fog Settings")]
    public bool includeSkyboxInFog = true;
    [Tooltip("Controls the transition between day and night fog based on the light's angle. X-axis is light's vertical angle (-1 to 1), Y-axis is the blend factor (0=night, 1=day).")]
    public AnimationCurve dayNightCurve = new AnimationCurve(new Keyframe(-0.2f, 0), new Keyframe(0.2f, 1));
    [Space]
    public float fogStartDistance = 128;
    public float fogHeightStart = 0;
    public float fogHeightEnd = 512;
    [Range(0, 1)] public float fogIntensity = 1.0f;

    [Header("Fog Day Settings")]
    public Color dayFogColor = new Color(0.7f, 0.8f, 1.0f);
    [Range(0.001f, 0.1f)] public float dayFogDensity = 0.01f;
    [Range(0, 10)] public float dayGlowIntensity = 1.0f;

    [Header("Fog Night Settings")]
    public Color nightFogColor = new Color(0.05f, 0.1f, 0.2f);
    [Range(0.001f, 0.1f)] public float nightFogDensity = 0.05f;
    [Range(0, 10)] public float nightGlowIntensity = 0.5f;

    [Header("God Rays")]
    [Range(0.1f, 1.0f)] public float godRayResolutionScale = 0.5f;
    [Range(16, 128)] public int godRaySamples = 64;
    [Range(0.8f, 0.99f)] public float godRayWeight = 0.95f;
    [Range(0.0f, 2.0f)] public float godRayIntensity = 0.5f;
    public Color godRayColor = Color.white;

    private const int PASS_CLOUDS = 0;
    private const int PASS_COMPOSITE = 1;
    private const int PASS_GAUSSIAN = 2;
    private const int PASS_TEMPORAL = 3;
    private const int PASS_COPY = 4;
    private const int PASS_SCENE_FOG = 5;
    private const int PASS_GODRAY_MASK = 6;
    private const int PASS_GODRAY_BLUR = 7;
    private const int PASS_GODRAY_COMPOSITE = 8;

    void OnEnable()
    {
        _atmosphereShader = Resources.Load<Shader>("VolumetricAtmosphere");
        if (_atmosphereShader == null) { Debug.LogError("VolumetricAtmosphere.shader not found in a Resources folder."); return; }
        Camera.onPreRender += OnPreRenderCamera;
    }

    void OnDisable()
    {
        Camera.onPreRender -= OnPreRenderCamera;
        var cameras = new List<Camera>(_cameraData.Keys);
        foreach (var cam in cameras)
        {
            if (cam != null && _cameraData.ContainsKey(cam))
            {
                var data = _cameraData[cam];
                if (data.commandBuffer != null)
                {
                    cam.RemoveCommandBuffer(CameraEvent.BeforeImageEffectsOpaque, data.commandBuffer);
                }
                data.Release();
            }
        }
        _cameraData.Clear();
    }

    void AutoDetectSun()
    {
        if (directionalLight == null) directionalLight = RenderSettings.sun;
        if (directionalLight == null)
        {
            Light[] lights = FindObjectsOfType<Light>();
            foreach (Light light in lights)
            {
                if (light.type == LightType.Directional)
                {
                    directionalLight = light;
                    return;
                }
            }
        }
    }

    void OnPreRenderCamera(Camera cam)
    {
        if (cam.cameraType == CameraType.Preview || cam.cameraType == CameraType.Reflection || _atmosphereShader == null) return;

        bool isEffectActive = enableClouds || enableFog || (enableGodRays && directionalLight != null);

        if (!_cameraData.ContainsKey(cam))
        {
            var newData = new CameraData();
            newData.commandBuffer = new CommandBuffer { name = "Volumetric Atmosphere" };
            newData.materialInstance = new Material(_atmosphereShader);
            newData.prevViewProjMatrix = cam.projectionMatrix * cam.worldToCameraMatrix;
            cam.AddCommandBuffer(CameraEvent.BeforeImageEffectsOpaque, newData.commandBuffer);
            _cameraData.Add(cam, newData);
        }

        var data = _cameraData[cam];
        var cmd = data.commandBuffer;
        var material = data.materialInstance;

        cmd.Clear();

        if (!isEffectActive) return;

        cam.depthTextureMode |= DepthTextureMode.Depth | DepthTextureMode.DepthNormals;
        AutoDetectSun();

        if (enableClouds) material.EnableKeyword("ENABLE_CLOUDS"); else material.DisableKeyword("ENABLE_CLOUDS");
        if (enableFog) material.EnableKeyword("ENABLE_FOG"); else material.DisableKeyword("ENABLE_FOG");
        if (enableGodRays && directionalLight) material.EnableKeyword("ENABLE_GODRAYS"); else material.DisableKeyword("ENABLE_GODRAYS");

        Matrix4x4 projMatrix = GL.GetGPUProjectionMatrix(cam.projectionMatrix, false);
        Matrix4x4 viewMatrix = cam.worldToCameraMatrix;
        Matrix4x4 viewProjMatrix = projMatrix * viewMatrix;

        int lowResW = (int)(cam.pixelWidth * resolutionScale);
        int lowResH = (int)(cam.pixelHeight * resolutionScale);
        int fullResW = cam.pixelWidth;
        int fullResH = cam.pixelHeight;

        material.SetVector("_LowResScreenParams", new Vector4(lowResW, lowResH, 1.0f / lowResW, 1.0f / lowResH));
        material.SetMatrix("_InverseProjection", projMatrix.inverse);
        material.SetMatrix("_InverseView", viewMatrix.inverse);
        material.SetMatrix("_PrevViewProjMatrix", data.prevViewProjMatrix);
        material.SetFloat("_CloudMinHeight", cloudMinHeight);
        material.SetFloat("_CloudMaxHeight", cloudMaxHeight);
        material.SetVector("_NoiseSeedOffset", noiseSeedOffset);
        material.SetVector("_WindDirection", windDirection.normalized);
        material.SetFloat("_WindSpeed", windSpeed);
        material.SetFloat("_Density", density);
        material.SetFloat("_LightAbsorption", lightAbsorption);
        material.SetFloat("_NoiseScale", noiseScale);
        material.SetFloat("_Coverage", coverage);
        material.SetFloat("_CloudMorphSpeed", cloudMorphSpeed);
        material.SetColor("_CloudColor", cloudColor);
        material.SetColor("_SunColor", directionalLight ? directionalLight.color * directionalLight.intensity : sunColor);
        material.SetVector("_LightDir", directionalLight ? -directionalLight.transform.forward : Vector3.down);
        material.SetColor("_SkyColor", skyColor);
        material.SetFloat("_DetailIntensity", detailIntensity);
        material.SetFloat("_Softness", softness);
        material.SetFloat("_DetailNoiseScale", detailNoiseScale);
        material.SetFloat("_Curliness", curliness);
        material.SetFloat("_SilverLiningIntensity", silverLiningIntensity);
        material.SetFloat("_SilverLiningSpread", silverLiningSpread);
        material.SetInt("_Steps", steps);
        material.SetInt("_LightSteps", lightSteps);
        material.SetFloat("_TemporalBlendFactor", temporalBlendFactor);
        material.SetFloat("_UseTemporalDithering", useTemporalReprojection ? 1.0f : 0.0f);
        material.SetVector("_FullResTexelSize", new Vector4(1.0f / fullResW, 1.0f / fullResH, fullResW, fullResH));
        material.SetFloat("_SelfShadowStrength", selfShadowStrength);
        if (useCurvature) material.EnableKeyword("USE_CURVATURE"); else material.DisableKeyword("USE_CURVATURE");
        material.SetFloat("_PlanetRadius", planetRadius);
        if (useDistanceFade)
        {
            material.EnableKeyword("USE_DISTANCE_FADE");
            material.SetFloat("_FadeStartDistance", fadeStartDistance);
            material.SetFloat("_FadeEndDistance", fadeEndDistance);
        }
        else { material.DisableKeyword("USE_DISTANCE_FADE"); }

        if (directionalLight)
        {
            material.EnableKeyword("DIRECTIONAL_LIGHT_ON");
            Vector3 lightDir = directionalLight.transform.forward;
            float lightY = -lightDir.y;
            float dayNightFactor = dayNightCurve.Evaluate(lightY);

            Color currentFogColor = Color.Lerp(nightFogColor, dayFogColor, dayNightFactor);
            float currentFogDensity = Mathf.Lerp(nightFogDensity, dayFogDensity, dayNightFactor);
            float currentGlowIntensity = Mathf.Lerp(nightGlowIntensity, dayGlowIntensity, dayNightFactor);

            material.SetColor("_FogColor", currentFogColor);
            material.SetFloat("_FogDensity", currentFogDensity);
            material.SetFloat("_SunGlowIntensity", currentGlowIntensity);
            material.SetColor("_LightColor", directionalLight.color * directionalLight.intensity);
        }
        else
        {
            material.DisableKeyword("DIRECTIONAL_LIGHT_ON");
            material.SetColor("_FogColor", dayFogColor);
            material.SetFloat("_FogDensity", dayFogDensity);
        }
        material.SetFloat("_FogIntensity", fogIntensity);
        material.SetFloat("_FogStart", fogStartDistance);
        material.SetFloat("_FogHeightStart", fogHeightStart);
        material.SetFloat("_FogHeightEnd", fogHeightEnd);

        if (includeSkyboxInFog) material.EnableKeyword("FOG_INCLUDE_SKYBOX"); else material.DisableKeyword("FOG_INCLUDE_SKYBOX");

        // --- COMMAND BUFFER SETUP ---
        int cloudTextureID = Shader.PropertyToID("_CloudTexture");
        cmd.GetTemporaryRT(cloudTextureID, lowResW, lowResH, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
        cmd.Blit(null, cloudTextureID, material, PASS_CLOUDS);

        RenderTargetIdentifier filteredResult = cloudTextureID;
        if (enableClouds)
        {
            if (filterRadius > 0 && filterIterations > 0)
            {
                int upscaledID = Shader.PropertyToID("_UpscaledResult");
                cmd.GetTemporaryRT(upscaledID, fullResW, fullResH, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
                cmd.Blit(cloudTextureID, upscaledID, material, PASS_COPY);
                cmd.ReleaseTemporaryRT(cloudTextureID);

                int blurBufferID = Shader.PropertyToID("_BlurBuffer");
                cmd.GetTemporaryRT(blurBufferID, fullResW, fullResH, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
                material.SetFloat("_BlurRadius", filterRadius);
                material.SetFloat("_BlurDepthWeight", depthWeight);
                material.SetFloat("_BlurNormalWeight", normalWeight);
                RenderTargetIdentifier source = upscaledID;
                RenderTargetIdentifier dest = blurBufferID;
                for (int i = 0; i < filterIterations; i++)
                {
                    cmd.SetGlobalTexture("_BlurSourceTex", source);
                    cmd.Blit(source, dest, material, PASS_GAUSSIAN);
                    var temp = source; source = dest; dest = temp;
                }
                filteredResult = source;
                if (dest == (RenderTargetIdentifier)blurBufferID) cmd.ReleaseTemporaryRT(blurBufferID); else cmd.ReleaseTemporaryRT(upscaledID);
            }
            if (useTemporalReprojection)
            {
                if (data.historyTexture == null || data.historyTexture.width != fullResW || data.historyTexture.height != fullResH)
                {
                    if (data.historyTexture != null) data.historyTexture.Release();
                    data.historyTexture = new RenderTexture(fullResW, fullResH, 0, RenderTextureFormat.DefaultHDR, RenderTextureReadWrite.Linear);
                    data.historyTexture.Create();
                }
                int temporalResultID = Shader.PropertyToID("_TemporalResult");
                cmd.GetTemporaryRT(temporalResultID, fullResW, fullResH, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
                cmd.SetGlobalTexture("_CurrentFrameTex", filteredResult);
                cmd.SetGlobalTexture("_HistoryTex", data.historyTexture);
                cmd.Blit(null, temporalResultID, material, PASS_TEMPORAL);
                cmd.Blit(temporalResultID, data.historyTexture, material, PASS_COPY);
                if (filteredResult != (RenderTargetIdentifier)cloudTextureID) cmd.ReleaseTemporaryRT(Shader.PropertyToID(filteredResult.ToString()));
                filteredResult = new RenderTargetIdentifier(temporalResultID);
            }
        }

        int tempTargetID = Shader.PropertyToID("_TempCameraTarget");
        cmd.GetTemporaryRT(tempTargetID, -1, -1, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
        cmd.SetGlobalTexture("_CloudTex", filteredResult);
        cmd.Blit(BuiltinRenderTextureType.CameraTarget, tempTargetID, material, PASS_COMPOSITE);

        int sceneWithFogID = Shader.PropertyToID("_SceneWithFog");
        cmd.GetTemporaryRT(sceneWithFogID, -1, -1, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
        cmd.SetGlobalTexture("_MainTex", tempTargetID);
        cmd.Blit(tempTargetID, sceneWithFogID, material, PASS_SCENE_FOG);
        cmd.ReleaseTemporaryRT(tempTargetID);

        if (enableGodRays && directionalLight)
        {
            Vector3 sunWorldPos = cam.transform.position - directionalLight.transform.forward * 1000f;
            Vector3 sunScreenPos = cam.WorldToViewportPoint(sunWorldPos);

            if (sunScreenPos.z > 0)
            {
                material.SetVector("_LightScreenPos", new Vector4(sunScreenPos.x, sunScreenPos.y, 0, 0));
                material.SetFloat("_GodRayWeight", godRayWeight);
                material.SetInt("_GodRaySamples", godRaySamples);
                material.SetFloat("_GodRayIntensity", godRayIntensity);
                material.SetColor("_GodRayColor", godRayColor * directionalLight.intensity);

                int grWidth = (int)(cam.pixelWidth * godRayResolutionScale);
                int grHeight = (int)(cam.pixelHeight * godRayResolutionScale);

                int godRayMaskID = Shader.PropertyToID("_GodRayMask");
                cmd.GetTemporaryRT(godRayMaskID, grWidth, grHeight, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
                cmd.SetGlobalTexture("_MainTex", sceneWithFogID);
                cmd.Blit(sceneWithFogID, godRayMaskID, material, PASS_GODRAY_MASK);

                int godRayBlurID = Shader.PropertyToID("_GodRayBlur");
                cmd.GetTemporaryRT(godRayBlurID, grWidth, grHeight, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
                cmd.SetGlobalTexture("_MainTex", godRayMaskID);
                cmd.Blit(godRayMaskID, godRayBlurID, material, PASS_GODRAY_BLUR);
                cmd.ReleaseTemporaryRT(godRayMaskID);

                RenderTargetIdentifier godRayResult = godRayBlurID;

                if (filterRadius > 0 && filterIterations > 0)
                {
                    int blurBufferGodRayID = Shader.PropertyToID("_BlurBufferGodRay");
                    cmd.GetTemporaryRT(blurBufferGodRayID, grWidth, grHeight, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);

                    material.SetFloat("_BlurRadius", filterRadius);
                    material.SetFloat("_BlurDepthWeight", 0.0f);
                    material.SetFloat("_BlurNormalWeight", 0.0f);

                    int sourceID = godRayBlurID;
                    int destID = blurBufferGodRayID;

                    for (int i = 0; i < filterIterations; i++)
                    {
                        cmd.SetGlobalTexture("_BlurSourceTex", sourceID);
                        cmd.Blit(sourceID, destID, material, PASS_GAUSSIAN);
                        int temp = sourceID; sourceID = destID; destID = temp;
                    }

                    godRayResult = sourceID;
                    cmd.ReleaseTemporaryRT(destID);
                }

                if (useTemporalReprojection)
                {
                    if (data.historyGodRayTexture == null || data.historyGodRayTexture.width != grWidth || data.historyGodRayTexture.height != grHeight)
                    {
                        if (data.historyGodRayTexture != null) data.historyGodRayTexture.Release();
                        data.historyGodRayTexture = new RenderTexture(grWidth, grHeight, 0, RenderTextureFormat.DefaultHDR, RenderTextureReadWrite.Linear);
                        data.historyGodRayTexture.Create();
                    }
                    int temporalGodRayResultID = Shader.PropertyToID("_TemporalGodRayResult");
                    cmd.GetTemporaryRT(temporalGodRayResultID, grWidth, grHeight, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);

                    cmd.SetGlobalTexture("_CurrentFrameTex", godRayResult);
                    cmd.SetGlobalTexture("_HistoryTex", data.historyGodRayTexture);

                    cmd.Blit(null, temporalGodRayResultID, material, PASS_TEMPORAL);
                    cmd.Blit(temporalGodRayResultID, data.historyGodRayTexture, material, PASS_COPY);

                    cmd.ReleaseTemporaryRT(Shader.PropertyToID(godRayResult.ToString()));
                    godRayResult = new RenderTargetIdentifier(temporalGodRayResultID);
                }

                cmd.SetGlobalTexture("_GodRayTex", godRayResult);
                cmd.SetGlobalTexture("_MainTex", sceneWithFogID);
                cmd.Blit(sceneWithFogID, BuiltinRenderTextureType.CameraTarget, material, PASS_GODRAY_COMPOSITE);

                cmd.ReleaseTemporaryRT(Shader.PropertyToID(godRayResult.ToString()));
            }
            else
            {
                // Sun is behind camera, so just draw the scene with fog
                cmd.Blit(sceneWithFogID, BuiltinRenderTextureType.CameraTarget);
            }
        }
        else
        {
            // God Rays are disabled, so just draw the scene with fog
            cmd.Blit(sceneWithFogID, BuiltinRenderTextureType.CameraTarget);
        }

        cmd.ReleaseTemporaryRT(sceneWithFogID);

        if (filteredResult.ToString() != cloudTextureID.ToString()) cmd.ReleaseTemporaryRT(Shader.PropertyToID(filteredResult.ToString()));
        cmd.ReleaseTemporaryRT(cloudTextureID);

        data.prevViewProjMatrix = viewProjMatrix;
    }


    #if UNITY_EDITOR
        [MenuItem("GameObject/YmneFX/Volumetric Atmosphere", false, 10)]
        static void CreateVolumetricAtmosphere(MenuCommand menuCommand)
        {
            GameObject go = new GameObject("Volumetric Atmosphere");
            go.AddComponent<VolumetricAtmosphere>();

            GameObjectUtility.SetParentAndAlign(go, menuCommand.context as GameObject);

            Undo.RegisterCreatedObjectUndo(go, "Create Volumetric Atmosphere");
            Selection.activeObject = go;
        }
    #endif
}