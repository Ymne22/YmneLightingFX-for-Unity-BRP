using UnityEngine;
using UnityEngine.Rendering;
using System.Collections.Generic;

[ExecuteInEditMode]
[AddComponentMenu("Image Effects/Rendering/SSGI Manager")]
public class SSGI : MonoBehaviour
{
    // This class holds all the per-camera data
    private class CameraData
    {
        public CommandBuffer commandBuffer;
        public Material materialInstance; // Each camera gets its own material
        public Matrix4x4 prevViewProjMatrix;
        public RenderTexture historyTexture;
        public Vector3 lastPosition;
        public Quaternion lastRotation;

        public void Release()
        {
            if (commandBuffer != null)
            {
                commandBuffer.Release();
                commandBuffer = null;
            }
            if (historyTexture != null)
            {
                historyTexture.Release();
                Object.DestroyImmediate(historyTexture);
                historyTexture = null;
            }
            if (materialInstance != null)
            {
                Object.DestroyImmediate(materialInstance);
                materialInstance = null;
            }
        }
    }

    private Shader _shader;
    private Dictionary<Camera, CameraData> _cameraData = new Dictionary<Camera, CameraData>();

    [Header("Ray-Marching")]
    [Range(1, 32)]
    public int sampleCount = 8;
    [Range(0.1f, 100f)]
    public float maxGIRayDistance = 25.0f;
    [Range(0.01f, 128.0f)]
    public float intersectionThickness = 64.0f;

    [Header("Lighting")]
    [Range(0.01f, 5.0f)]
    public float giIntensity = 1.0f;
    [Range(1.0f, 20.0f)]
    public float sampleClampValue = 5.0f;
    [Tooltip("Use physically-based cosine-weighted sampling for GI.")]
    public bool cosineWeightedSampling = true;

    [Header("Temporal Reprojection")]
    public bool useTemporalReprojection = true;
    [Range(0.0f, 1.0f)]
    public float temporalBlendFactor = 0.9f;
    [Tooltip("Resets the history buffer when the camera moves or rotates too quickly.")]
    public bool resetHistoryOnTeleport = true;
    [Tooltip("The distance the camera has to move in one frame to trigger a history reset.")]
    public float teleportThreshold = 2.0f;

    [Header("Performance & Filtering")]
    [Range(0.25f, 1.0f)]
    public float resolutionScale = 0.5f;
    [Range(0, 8)]
    public int filterIterations = 1;
    [Range(0.0f, 2.0f)]
    public float filterRadius = 1.0f;
    [Range(0.0f, 50.0f)]
    public float depthWeight = 10.0f;
    [Range(0.0f, 100.0f)]
    public float normalWeight = 20.0f;

    private const int PASS_SSGI = 0;
    private const int PASS_COMPOSITE = 1;
    private const int PASS_GAUSSIAN = 2;
    private const int PASS_TEMPORAL = 3;
    private const int PASS_COPY = 4;

    void OnEnable()
    {
        if (_shader == null)
        {
            _shader = Resources.Load<Shader>("SSGI");
            if (_shader == null)
            {
                Debug.LogError("SSGI.shader not found in Resources folder.");
                return;
            }
        }
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
    
    void OnPreRenderCamera(Camera cam)
    {
        if (cam.cameraType == CameraType.Preview || cam.cameraType == CameraType.Reflection) return;
        
        if (_shader == null) return;

        if (!_cameraData.ContainsKey(cam))
        {
            var newData = new CameraData();
            newData.commandBuffer = new CommandBuffer { name = "SSGI" };
            newData.materialInstance = new Material(_shader); // Create a unique material
            newData.prevViewProjMatrix = cam.projectionMatrix * cam.worldToCameraMatrix;
            newData.lastPosition = cam.transform.position;
            newData.lastRotation = cam.transform.rotation;
            cam.AddCommandBuffer(CameraEvent.BeforeImageEffectsOpaque, newData.commandBuffer);
            _cameraData.Add(cam, newData);
        }
        
        var data = _cameraData[cam];
        var cmd = data.commandBuffer;
        var material = data.materialInstance; // Use the per-camera material
        
        var depthFlags = DepthTextureMode.Depth | DepthTextureMode.DepthNormals;
        if (useTemporalReprojection) depthFlags |= DepthTextureMode.MotionVectors;
        cam.depthTextureMode |= depthFlags;

        cmd.Clear();
        
        int lowResW = (int)(cam.pixelWidth * resolutionScale);
        int lowResH = (int)(cam.pixelHeight * resolutionScale);
        int fullResW = cam.pixelWidth;
        int fullResH = cam.pixelHeight;
        
        Matrix4x4 projMatrix = GL.GetGPUProjectionMatrix(cam.projectionMatrix, false);
        Matrix4x4 viewMatrix = cam.worldToCameraMatrix;
        Matrix4x4 viewProjMatrix = projMatrix * viewMatrix;

        material.SetMatrix("_InverseProjection", projMatrix.inverse);
        material.SetMatrix("_Projection", projMatrix);
        material.SetMatrix("_InverseView", viewMatrix.inverse);
        material.SetMatrix("_PrevViewProjMatrix", data.prevViewProjMatrix);
        material.SetInt("_SampleCount", sampleCount);
        material.SetFloat("_GIIntensity", giIntensity);
        material.SetFloat("_MaxGIRayDistance", maxGIRayDistance);
        material.SetFloat("_CosineWeightedSampling", cosineWeightedSampling ? 1.0f : 0.0f);
        material.SetFloat("_IntersectionThickness", intersectionThickness);
        material.SetFloat("_SampleClampValue", sampleClampValue);
        material.SetFloat("_TemporalBlendFactor", temporalBlendFactor);
        material.SetVector("_FullResTexelSize", new Vector4(1.0f / fullResW, 1.0f / fullResH, fullResW, fullResH));
        
        // --- DITHERING CONTROL ---
        material.SetFloat("_UseTemporalDithering", useTemporalReprojection ? 1.0f : 0.0f);
        
        int ssgiTextureID = Shader.PropertyToID("_SSGITexture");
        cmd.GetTemporaryRT(ssgiTextureID, lowResW, lowResH, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
        cmd.Blit(null, ssgiTextureID, material, PASS_SSGI);
        
        RenderTargetIdentifier filteredResult = ssgiTextureID;
        if (filterRadius > 0 && filterIterations > 0)
        {
            int upscaledID = Shader.PropertyToID("_UpscaledResult");
            cmd.GetTemporaryRT(upscaledID, fullResW, fullResH, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
            cmd.SetGlobalTexture("_MainTex", ssgiTextureID);
            cmd.Blit(ssgiTextureID, upscaledID, material, PASS_COPY);
            cmd.ReleaseTemporaryRT(ssgiTextureID);

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

        RenderTargetIdentifier finalResult;

        if (useTemporalReprojection)
        {
            if (resetHistoryOnTeleport && Vector3.Distance(data.lastPosition, cam.transform.position) > teleportThreshold)
            {
                if (data.historyTexture != null)
                {
                    data.historyTexture.Release();
                    Object.DestroyImmediate(data.historyTexture);
                    data.historyTexture = null;
                }
            }
            
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
            
            cmd.SetGlobalTexture("_MainTex", temporalResultID);
            cmd.Blit(temporalResultID, data.historyTexture, material, PASS_COPY);
            finalResult = new RenderTargetIdentifier(temporalResultID);
        }
        else
        {
            if (data.historyTexture != null)
            {
                data.historyTexture.Release();
                Object.DestroyImmediate(data.historyTexture);
                data.historyTexture = null;
            }
            finalResult = filteredResult;
        }

        cmd.SetGlobalTexture("_AccumulatedSSGITex", finalResult);
        int tempTargetID = Shader.PropertyToID("_TempCameraTarget");
        cmd.GetTemporaryRT(tempTargetID, -1, -1, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
        
        cmd.SetGlobalTexture("_MainTex", BuiltinRenderTextureType.CameraTarget);
        cmd.Blit(BuiltinRenderTextureType.CameraTarget, tempTargetID, material, PASS_COPY);

        cmd.SetGlobalTexture("_MainTex", tempTargetID);
        cmd.Blit(tempTargetID, BuiltinRenderTextureType.CameraTarget, material, PASS_COMPOSITE);
        cmd.ReleaseTemporaryRT(tempTargetID);

        // --- Release all temporary textures used in the frame ---
        if (finalResult.ToString() != filteredResult.ToString()) cmd.ReleaseTemporaryRT(Shader.PropertyToID(finalResult.ToString()));
        if (filteredResult.ToString() != ssgiTextureID.ToString()) cmd.ReleaseTemporaryRT(Shader.PropertyToID(filteredResult.ToString()));
        cmd.ReleaseTemporaryRT(ssgiTextureID);

        data.prevViewProjMatrix = viewProjMatrix;
        data.lastPosition = cam.transform.position;
        data.lastRotation = cam.transform.rotation;
    }
}
