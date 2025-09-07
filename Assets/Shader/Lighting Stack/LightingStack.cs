#if UNITY_EDITOR
using UnityEditor;
#endif

using UnityEngine;
using UnityEngine.Rendering;
using System.Collections.Generic;
using System.Linq;

[ExecuteInEditMode]
[AddComponentMenu("Image Effects/Rendering/Lighting Stack")]
public class LightingStack : MonoBehaviour
{
    // Holds all per-camera data to avoid conflicts
    private class CameraData
    {
        public CommandBuffer commandBuffer;
        public Material materialInstance;
        public Matrix4x4 prevViewProjMatrix;
        public Vector3 lastPosition;
        public Quaternion lastRotation;

        public RenderTexture historySSGI;
        public RenderTexture historySSAO;
        public RenderTexture historySSR;
        public RenderTexture historySSDCS;

        public void Release()
        {
            if (commandBuffer != null) { commandBuffer.Release(); commandBuffer = null; }
            ReleaseTexture(historySSGI); historySSGI = null;
            ReleaseTexture(historySSAO); historySSAO = null;
            ReleaseTexture(historySSR); historySSR = null;
            ReleaseTexture(historySSDCS); historySSDCS = null;
            if (materialInstance != null) { Object.DestroyImmediate(materialInstance); materialInstance = null; }
        }

        private void ReleaseTexture(RenderTexture tex)
        {
            if (tex != null) { tex.Release(); Object.DestroyImmediate(tex); }
        }
    }

    private Shader _shader;
    private Dictionary<Camera, CameraData> _cameraData = new Dictionary<Camera, CameraData>();

    // Pass indices in the shader
    private const int PASS_SSGI = 0;
    private const int PASS_SSAO = 1;
    private const int PASS_SSR = 2;
    private const int PASS_SSDCS = 3;
    private const int PASS_GAUSSIAN_BLUR = 4;
    private const int PASS_TEMPORAL = 5;
    private const int PASS_COMPOSITE_SSGI = 6;
    private const int PASS_COMPOSITE_SSAO = 7;
    private const int PASS_COMPOSITE_SSR = 8;
    private const int PASS_COMPOSITE_SSDCS = 9;

    [Header("Global Toggles")]
    public bool enableSSGI = true;
    public bool enableSSAO = true;
    public bool enableSSR = true;
    public bool enableSSDCS = false;

    [Header("Temporal Reprojection")]
    public bool enableTemporalReprojection = true;
    public bool resetHistoryOnTeleport = true;
    [Range(0.0f, 1.0f)] public float temporalBlendFactor = 0.95f;

    [Range(0.0f, 10.0f)] public float teleportThreshold = 2.0f;

    [Header("SSGI - Screen-Space Global Illumination")]
    [Range(0.1f, 1.0f)] public float SSGIResolutionScale = 0.5f;
    [Range(1, 32)] public int SSGISampleCount = 8;
    [Range(0.1f, 100f)] public float SSGIMaxRayDistance = 96.0f;
    [Range(0.01f, 128.0f)] public float SSGIIntersectionThickness = 128.0f;
    [Range(0.01f, 1.0f)] public float SSGIIntensity = 1.0f;
    [Range(1.0f, 20.0f)] public float SSGISampleClampValue = 6.0f;
    [Range(0, 4)] public int SSGIFilterIterations = 1;
    [Range(0.0f, 4.0f)] public float SSGIFilterRadius = 4.0f;
    public bool SSGICosineWeightedSampling = true;

    [Header("SSAO - Screen-Space Ambient Occlusion")]
    [Range(0.1f, 1.0f)] public float SSAOResolutionScale = 0.5f;
    [Range(1, 32)] public int SSAOSampleCount = 8;
    [Range(0.01f, 32.0f)] public float SSAORadius = 8.0f;
    [Range(0.0f, 1.0f)] public float SSAOIntensity = 1.0f;
    [Range(0.1f, 4.0f)] public float SSAOPower = 4.0f;
    [Range(0, 4)] public int SSAOFilterIterations = 1;
    [Range(0.0f, 4.0f)] public float SSAOFilterRadius = 4.0f;

    [Header("SSR - Screen-Space Reflections")]
    [Range(0.1f, 1.0f)] public float SSRResolutionScale = 0.5f;
    [Range(1, 64)] public int SSRSampleCount = 8;
    [Range(0.1f, 100f)] public float SSRMaxRayDistance = 32.0f;
    [Range(0.01f, 5.0f)] public float SSRIntersectionThickness = 1.0f;
    [Range(0.01f, 1.0f)] public float SSRReflectionIntensity = 1.0f;
    [Range(0.0f, 10.0f)] public float SSRRoughnessContrast = 8.0f;
    [Range(1.0f, 20.0f)] public float SSRSampleClampValue = 5.0f;
    [Range(0.0f, 1.0f)] public float SSRMinSmoothness = 0.6f;
    [Range(0, 4)] public int SSRFilterIterations = 1;
    [Range(0.0f, 4.0f)] public float SSRFilterRadius = 4.0f;

    [Header("SSDCS - Screen-Space Directional Contact Shadows (Experimental)")]
    [Range(0.1f, 1.0f)] public float SSDCSResolutionScale = 0.5f;
    [Range(1, 4)] public int SSDCSSampleCount = 12;
    [Range(0.01f, 5.0f)] public float SSDCSMaxRayDistance = 0.5f;
    [Range(0.001f, 0.5f)] public float SSDCSThickness = 0.05f;
    [Range(0.0f, 10.0f)] public float SSDCSIntensity = 1.0f;
    [Range(0, 4)] public int SSDCSFilterIterations = 2;
    [Range(0.0f, 4.0f)] public float SSDCSFilterRadius = 1.0f;

    [Header("Advanced Filtering Weights")]
    [Range(0.0f, 50.0f)] public float filterDepthWeight = 10.0f;
    [Range(0.0f, 100.0f)] public float filterNormalWeight = 20.0f;

    private struct EffectSettings
    {
        public int Pass;
        public int CompositePass;
        public string Name;
        public RenderTargetIdentifier SourceTarget;
        public float ResolutionScale;
        public bool HistoryReset;
        public bool IsSingleChannel;
        public int FilterIterations;
        public float FilterRadius;
    }

    void OnEnable()
    {
        _shader = Resources.Load<Shader>("LightingStack");
        if (_shader == null) { Debug.LogError("LightingStack.shader not found in Resources folder."); return; }
        Camera.onPreRender += OnPreRenderCamera;
    }

    void OnDisable()
    {
        Camera.onPreRender -= OnPreRenderCamera;
        foreach (var cam in new List<Camera>(_cameraData.Keys))
        {
            if (cam != null && _cameraData.ContainsKey(cam))
            {
                var data = _cameraData[cam];
                if (data.commandBuffer != null) { cam.RemoveCommandBuffer(CameraEvent.BeforeImageEffectsOpaque, data.commandBuffer); }
                data.Release();
            }
        }
        _cameraData.Clear();
    }

    void OnPreRenderCamera(Camera cam)
    {
        if (cam.cameraType == CameraType.Preview || cam.cameraType == CameraType.Reflection || _shader == null) return;

        bool anyEffectEnabled = enableSSGI || enableSSAO || enableSSR || enableSSDCS;
        if (!anyEffectEnabled)
        {
            if (_cameraData.ContainsKey(cam))
            {
                var oldData = _cameraData[cam];
                if (oldData.commandBuffer != null) cam.RemoveCommandBuffer(CameraEvent.BeforeImageEffectsOpaque, oldData.commandBuffer);
                oldData.Release();
                _cameraData.Remove(cam);
            }
            return;
        }

        if (!_cameraData.ContainsKey(cam))
        {
            var newData = new CameraData
            {
                commandBuffer = new CommandBuffer { name = "Lighting Stack" },
                materialInstance = new Material(_shader),
                prevViewProjMatrix = cam.projectionMatrix * cam.worldToCameraMatrix,
                lastPosition = cam.transform.position,
                lastRotation = cam.transform.rotation
            };
            cam.AddCommandBuffer(CameraEvent.BeforeImageEffectsOpaque, newData.commandBuffer);
            _cameraData.Add(cam, newData);
        }

        var data = _cameraData[cam];
        var cmd = data.commandBuffer;
        var material = data.materialInstance;

        var depthFlags = DepthTextureMode.Depth | DepthTextureMode.DepthNormals;
        if (enableTemporalReprojection) { depthFlags |= DepthTextureMode.MotionVectors; }
        cam.depthTextureMode = depthFlags;

        cmd.Clear();

        int fullResW = cam.pixelWidth;
        int fullResH = cam.pixelHeight;
        Matrix4x4 projMatrix = GL.GetGPUProjectionMatrix(cam.projectionMatrix, false);
        Matrix4x4 viewMatrix = cam.worldToCameraMatrix;
        Matrix4x4 viewProjMatrix = projMatrix * viewMatrix;

        material.SetMatrix("_InverseProjection", projMatrix.inverse);
        material.SetMatrix("_Projection", projMatrix);
        material.SetMatrix("_InverseView", viewMatrix.inverse);
        material.SetMatrix("_PrevViewProjMatrix", data.prevViewProjMatrix);
        material.SetVector("_FullResTexelSize", new Vector4(1.0f / fullResW, 1.0f / fullResH, fullResW, fullResH));
        material.SetFloat("_UseTemporalDithering", enableTemporalReprojection ? 1.0f : 0.0f);

        int lightingResultID = Shader.PropertyToID("_LightingResultTarget");
        cmd.GetTemporaryRT(lightingResultID, -1, -1, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
        cmd.Blit(BuiltinRenderTextureType.CameraTarget, lightingResultID);

        bool historyReset = resetHistoryOnTeleport && Vector3.Distance(data.lastPosition, cam.transform.position) > teleportThreshold;

        // --- RENDER PASSES ---

        if (enableSSGI)
        {
            ApplyEffect(cmd, cam, material, ref data.historySSGI, new EffectSettings { Pass = PASS_SSGI, CompositePass = PASS_COMPOSITE_SSGI, Name = "SSGI", ResolutionScale = SSGIResolutionScale, FilterIterations = SSGIFilterIterations, FilterRadius = SSGIFilterRadius, SourceTarget = lightingResultID, HistoryReset = historyReset });
        }

        if (enableSSR)
        {
            ApplySSR(cmd, cam, material, ref data.historySSR, lightingResultID, historyReset);
        }

        if (enableSSDCS)
        {
            ApplySSDCS(cmd, cam, material, ref data.historySSDCS, lightingResultID, historyReset);
        }

        if (enableSSAO)
        {
            ApplyEffect(cmd, cam, material, ref data.historySSAO, new EffectSettings { Pass = PASS_SSAO, CompositePass = PASS_COMPOSITE_SSAO, Name = "SSAO", ResolutionScale = SSAOResolutionScale, FilterIterations = SSAOFilterIterations, FilterRadius = SSAOFilterRadius, SourceTarget = lightingResultID, HistoryReset = historyReset, IsSingleChannel = true });
        }

        cmd.Blit(lightingResultID, BuiltinRenderTextureType.CameraTarget);
        cmd.ReleaseTemporaryRT(lightingResultID);

        data.prevViewProjMatrix = viewProjMatrix;
        data.lastPosition = cam.transform.position;
        data.lastRotation = cam.transform.rotation;
    }

    private Light FindDirectionalLight()
    {
        // Find and detect the first active directional light in the scene.
        return FindObjectsOfType<Light>()
            .FirstOrDefault(l => l.isActiveAndEnabled && l.type == LightType.Directional);
    }

    private void ApplySSR(CommandBuffer cmd, Camera cam, Material material, ref RenderTexture historyBuffer, RenderTargetIdentifier source, bool historyReset)
    {
        int lowResW = (int)(cam.pixelWidth * SSRResolutionScale);
        int lowResH = (int)(cam.pixelHeight * SSRResolutionScale);
        int fullResW = cam.pixelWidth;
        int fullResH = cam.pixelHeight;

        material.SetInt("_SSR_SampleCount", SSRSampleCount);
        material.SetFloat("_SSR_MaxRayDistance", SSRMaxRayDistance);
        material.SetFloat("_SSR_IntersectionThickness", SSRIntersectionThickness);
        material.SetFloat("_SSR_SampleClampValue", SSRSampleClampValue);
        material.SetFloat("_SSR_MinSmoothness", SSRMinSmoothness);
        material.SetFloat("_SSR_Intensity", SSRReflectionIntensity);
        material.SetFloat("_SSR_RoughnessContrast", SSRRoughnessContrast);

        int rawSSR_ID = Shader.PropertyToID("_RawSSR");
        cmd.GetTemporaryRT(rawSSR_ID, lowResW, lowResH, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
        cmd.Blit(null, rawSSR_ID, material, PASS_SSR);

        RenderTargetIdentifier filteredSSR = ExecuteGaussianBlur(cmd, material, rawSSR_ID, lowResW, lowResH, fullResW, fullResH, SSRFilterIterations, SSRFilterRadius, RenderTextureFormat.DefaultHDR);

        RenderTargetIdentifier finalSsrResult;
        if (enableTemporalReprojection)
        {
            if (historyReset && historyBuffer != null) { historyBuffer.Release(); DestroyImmediate(historyBuffer); historyBuffer = null; }
            if (historyBuffer == null || historyBuffer.width != fullResW || historyBuffer.height != fullResH)
            {
                if (historyBuffer != null) { historyBuffer.Release(); DestroyImmediate(historyBuffer); }
                historyBuffer = new RenderTexture(fullResW, fullResH, 0, RenderTextureFormat.DefaultHDR, RenderTextureReadWrite.Linear);
                historyBuffer.Create();
            }

            int temporalResultID = Shader.PropertyToID("_TemporalResultSSR");
            cmd.GetTemporaryRT(temporalResultID, fullResW, fullResH, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
            cmd.SetGlobalTexture("_CurrentFrameTex", filteredSSR);
            cmd.SetGlobalTexture("_HistoryTex", historyBuffer);
            material.SetFloat("_TemporalBlendFactor", temporalBlendFactor);
            cmd.Blit(null, temporalResultID, material, PASS_TEMPORAL);

            cmd.Blit(temporalResultID, historyBuffer);
            finalSsrResult = new RenderTargetIdentifier(temporalResultID);
        }
        else { finalSsrResult = filteredSSR; }

        int tempCompositeTarget = Shader.PropertyToID("_TempCompositeTarget");
        cmd.GetTemporaryRT(tempCompositeTarget, -1, -1, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
        cmd.SetGlobalTexture("_EffectTex", finalSsrResult);
        cmd.SetGlobalTexture("_MainTex", source);
        cmd.Blit(source, tempCompositeTarget, material, PASS_COMPOSITE_SSR);
        cmd.Blit(tempCompositeTarget, source);
        cmd.ReleaseTemporaryRT(tempCompositeTarget);

        cmd.ReleaseTemporaryRT(rawSSR_ID);
        if (filteredSSR.ToString() != rawSSR_ID.ToString()) cmd.ReleaseTemporaryRT(Shader.PropertyToID(filteredSSR.ToString()));
        if (enableTemporalReprojection) cmd.ReleaseTemporaryRT(Shader.PropertyToID(finalSsrResult.ToString()));
    }

    private void ApplySSDCS(CommandBuffer cmd, Camera cam, Material material, ref RenderTexture historyBuffer, RenderTargetIdentifier source, bool historyReset)
    {
        Light directionalLight = FindDirectionalLight();
        if (directionalLight == null) return;

        material.SetInt("_SSDCS_SampleCount", SSDCSSampleCount);
        material.SetFloat("_SSDCS_MaxRayDistance", SSDCSMaxRayDistance);
        material.SetFloat("_SSDCS_Thickness", SSDCSThickness);
        material.SetFloat("_SSDCS_Intensity", SSDCSIntensity);
        material.SetVector("_SSDCS_LightDirVS", cam.worldToCameraMatrix.MultiplyVector(directionalLight.transform.forward));

        int lowResW = (int)(cam.pixelWidth * SSDCSResolutionScale);
        int lowResH = (int)(cam.pixelHeight * SSDCSResolutionScale);
        RenderTextureFormat format = RenderTextureFormat.RHalf;

        int rawShadowsId = Shader.PropertyToID("_RawSSDCS");
        cmd.GetTemporaryRT(rawShadowsId, lowResW, lowResH, 0, FilterMode.Bilinear, format);

        cmd.Blit(null, rawShadowsId, material, PASS_SSDCS);

        int fullResW = cam.pixelWidth;
        int fullResH = cam.pixelHeight;
        RenderTargetIdentifier filteredResult = ExecuteGaussianBlur(
            cmd, material, rawShadowsId, lowResW, lowResH, fullResW, fullResH,
            SSDCSFilterIterations, SSDCSFilterRadius, format
        );

        RenderTargetIdentifier finalResult;
        if (enableTemporalReprojection)
        {
            if (historyReset && historyBuffer != null)
            {
                historyBuffer.Release();
                Object.DestroyImmediate(historyBuffer);
                historyBuffer = null;
            }
            if (historyBuffer == null || historyBuffer.width != fullResW || historyBuffer.height != fullResH)
            {
                if (historyBuffer != null)
                {
                    historyBuffer.Release();
                    Object.DestroyImmediate(historyBuffer);
                }
                historyBuffer = new RenderTexture(fullResW, fullResH, 0, format, RenderTextureReadWrite.Linear);
                historyBuffer.Create();
            }
            int temporalResultID = Shader.PropertyToID("_TemporalResultSSDCS");
            cmd.GetTemporaryRT(temporalResultID, fullResW, fullResH, 0, FilterMode.Bilinear, format);
            cmd.SetGlobalTexture("_CurrentFrameTex", filteredResult);
            cmd.SetGlobalTexture("_HistoryTex", historyBuffer);
            material.SetFloat("_TemporalBlendFactor", temporalBlendFactor);
            cmd.Blit(null, temporalResultID, material, PASS_TEMPORAL);
            cmd.Blit(temporalResultID, historyBuffer);
            finalResult = new RenderTargetIdentifier(temporalResultID);
        }
        else
        {
            finalResult = filteredResult;
        }

        int tempCompositeTarget = Shader.PropertyToID("_TempCompositeTargetSSDCS");
        cmd.GetTemporaryRT(tempCompositeTarget, -1, -1, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
        cmd.SetGlobalTexture("_EffectTex", finalResult);
        cmd.SetGlobalTexture("_MainTex", source);
        cmd.Blit(source, tempCompositeTarget, material, PASS_COMPOSITE_SSDCS);
        cmd.Blit(tempCompositeTarget, source);

        cmd.ReleaseTemporaryRT(tempCompositeTarget);
        if (finalResult != filteredResult) cmd.ReleaseTemporaryRT(Shader.PropertyToID(finalResult.ToString()));
        if (filteredResult.ToString() != rawShadowsId.ToString()) cmd.ReleaseTemporaryRT(Shader.PropertyToID(filteredResult.ToString()));
        cmd.ReleaseTemporaryRT(rawShadowsId);
    }

    private void ApplyEffect(CommandBuffer cmd, Camera cam, Material material, ref RenderTexture historyBuffer, EffectSettings settings)
    {
        switch (settings.Name)
        {
            case "SSGI":
                material.SetInt("_SSGI_SampleCount", SSGISampleCount);
                material.SetFloat("_SSGI_MaxRayDistance", SSGIMaxRayDistance);
                material.SetFloat("_SSGI_IntersectionThickness", SSGIIntersectionThickness);
                material.SetFloat("_SSGI_Intensity", SSGIIntensity);
                material.SetFloat("_SSGI_SampleClampValue", SSGISampleClampValue);
                material.SetFloat("_SSGI_CosineWeightedSampling", SSGICosineWeightedSampling ? 1.0f : 0.0f);
                break;
            case "SSAO":
                material.SetInt("_SSAO_SampleCount", SSAOSampleCount);
                material.SetFloat("_SSAO_Radius", SSAORadius);
                material.SetFloat("_SSAO_Power", SSAOPower);
                material.SetFloat("_SSAO_Intensity", SSAOIntensity);
                break;
        }

        int lowResW = (int)(cam.pixelWidth * settings.ResolutionScale);
        int lowResH = (int)(cam.pixelHeight * settings.ResolutionScale);
        int fullResW = cam.pixelWidth;
        int fullResH = cam.pixelHeight;
        RenderTextureFormat format = settings.IsSingleChannel ? RenderTextureFormat.RHalf : RenderTextureFormat.DefaultHDR;

        int rawEffectID = Shader.PropertyToID("_Raw" + settings.Name);
        cmd.GetTemporaryRT(rawEffectID, lowResW, lowResH, 0, FilterMode.Bilinear, format);
        cmd.Blit(null, rawEffectID, material, settings.Pass);

        RenderTargetIdentifier filteredResult = ExecuteGaussianBlur(cmd, material, rawEffectID, lowResW, lowResH, fullResW, fullResH, settings.FilterIterations, settings.FilterRadius, format);

        RenderTargetIdentifier finalResult;
        if (enableTemporalReprojection)
        {
            if (settings.HistoryReset && historyBuffer != null) { historyBuffer.Release(); Object.DestroyImmediate(historyBuffer); historyBuffer = null; }
            if (historyBuffer == null || historyBuffer.width != fullResW || historyBuffer.height != fullResH)
            {
                if (historyBuffer != null) { historyBuffer.Release(); Object.DestroyImmediate(historyBuffer); }
                historyBuffer = new RenderTexture(fullResW, fullResH, 0, format, RenderTextureReadWrite.Linear);
                historyBuffer.Create();
            }

            int temporalResultID = Shader.PropertyToID("_TemporalResult" + settings.Name);
            cmd.GetTemporaryRT(temporalResultID, fullResW, fullResH, 0, FilterMode.Bilinear, format);
            cmd.SetGlobalTexture("_CurrentFrameTex", filteredResult);
            cmd.SetGlobalTexture("_HistoryTex", historyBuffer);
            material.SetFloat("_TemporalBlendFactor", temporalBlendFactor);
            cmd.Blit(null, temporalResultID, material, PASS_TEMPORAL);

            cmd.Blit(temporalResultID, historyBuffer);
            finalResult = new RenderTargetIdentifier(temporalResultID);
        }
        else { finalResult = filteredResult; }

        int tempCompositeTarget = Shader.PropertyToID("_TempCompositeTarget");
        cmd.GetTemporaryRT(tempCompositeTarget, -1, -1, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
        cmd.SetGlobalTexture("_EffectTex", finalResult);
        cmd.SetGlobalTexture("_MainTex", settings.SourceTarget);
        cmd.Blit(settings.SourceTarget, tempCompositeTarget, material, settings.CompositePass);
        cmd.Blit(tempCompositeTarget, settings.SourceTarget);

        cmd.ReleaseTemporaryRT(tempCompositeTarget);
        if (finalResult != filteredResult) cmd.ReleaseTemporaryRT(Shader.PropertyToID(finalResult.ToString()));
        if (filteredResult.ToString() != rawEffectID.ToString()) cmd.ReleaseTemporaryRT(Shader.PropertyToID(filteredResult.ToString()));
        cmd.ReleaseTemporaryRT(rawEffectID);
    }

    private RenderTargetIdentifier ExecuteGaussianBlur(CommandBuffer cmd, Material material, RenderTargetIdentifier source, int lowW, int lowH, int fullW, int fullH, int iterations, float radius, RenderTextureFormat format)
    {
        if (radius <= 0 || iterations <= 0)
        {
            int finalID = Shader.PropertyToID("_FinalDirectBlit");
            cmd.GetTemporaryRT(finalID, fullW, fullH, 0, FilterMode.Bilinear, format);
            cmd.Blit(source, finalID);
            return finalID;
        }

        material.SetFloat("_BlurRadius", radius);
        material.SetFloat("_BlurDepthWeight", filterDepthWeight);
        material.SetFloat("_BlurNormalWeight", filterNormalWeight);

        int bufferA_ID = Shader.PropertyToID("_BlurBufferA");
        int bufferB_ID = Shader.PropertyToID("_BlurBufferB");
        cmd.GetTemporaryRT(bufferA_ID, fullW, fullH, 0, FilterMode.Bilinear, format);
        cmd.GetTemporaryRT(bufferB_ID, fullW, fullH, 0, FilterMode.Bilinear, format);

        cmd.Blit(source, bufferA_ID);

        RenderTargetIdentifier currentSource = bufferA_ID;
        RenderTargetIdentifier currentDest = bufferB_ID;

        for (int i = 0; i < iterations; i++)
        {
            cmd.SetGlobalTexture("_MainTex", currentSource);
            cmd.Blit(currentSource, currentDest, material, PASS_GAUSSIAN_BLUR);

            var temp = currentSource;
            currentSource = currentDest;
            currentDest = temp;
        }

        cmd.ReleaseTemporaryRT(Shader.PropertyToID(currentDest.ToString()));

        return currentSource;
    }
    
    #if UNITY_EDITOR
        [MenuItem("GameObject/YmneFX/Lighting Stack", false, 10)]
        static void CreateLightingStack(MenuCommand menuCommand)
        {
            GameObject go = new GameObject("Lighting Stack");
            go.AddComponent<LightingStack>();

            GameObjectUtility.SetParentAndAlign(go, menuCommand.context as GameObject);

            Undo.RegisterCreatedObjectUndo(go, "Create Lighting Stack");
            Selection.activeObject = go;
        }
#endif
}
