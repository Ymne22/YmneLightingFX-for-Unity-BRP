using UnityEngine;
using UnityEngine.Rendering;
using System.Collections.Generic;

[ExecuteInEditMode]
[AddComponentMenu("Image Effects/Rendering/SS-Bevel (Global)")]
public class SSBevel : MonoBehaviour
{
    private class CameraData
    {
        public CommandBuffer commandBuffer;
        public Material materialInstance;
        public Matrix4x4 prevViewProjMatrix;
        public RenderTexture historyTexture;
        public Vector3 lastPosition;
        public Quaternion lastRotation;

        public void Release()
        {
            if (commandBuffer != null) { commandBuffer.Release(); commandBuffer = null; }
            if (historyTexture != null) { historyTexture.Release(); Object.DestroyImmediate(historyTexture); historyTexture = null; }
            if (materialInstance != null) { Object.DestroyImmediate(materialInstance); materialInstance = null; }
        }
    }

    private Shader _shader;
    private Dictionary<Camera, CameraData> _cameraData = new Dictionary<Camera, CameraData>();

    [Header("Edge Detection")]
    [Tooltip("The screen-space radius to search for edges.")]
    [Range(0.001f, 0.1f)]
    public float radius = 0.03f;

    [Tooltip("The number of samples used to find edges. Higher is less noisy but costs more.")]
    [Range(1, 32)]
    public int sampleCount = 16;
    
    [Tooltip("Normal angle threshold. INCREASE this to include smoother edges.")]
    [Range(0.001f, 1.0f)]
    public float sharpness = 0.3f;

    [Tooltip("Maximum depth difference to consider a surface continuous. Prevents beveling across objects.")]
    [Range(0.001f, 1.0f)]
    public float depthThreshold = 0.5f;

    [Header("Final Effect")]
    [Tooltip("The final blend amount of the bled color.")]
    [Range(0.0f, 2.0f)]
    public float intensity = 1.0f;

    [Header("Temporal Reprojection")]
    public bool useTemporalReprojection = true;
    [Range(0.0f, 1.0f)]
    public float temporalBlendFactor = 0.9f;
    
    [Header("Performance & Filtering")]
    [Range(0.25f, 1.0f)]
    public float resolutionScale = 1.0f;
    [Range(0, 8)]
    public int filterIterations = 2;
    [Range(0.0f, 2.0f)]
    public float filterRadius = 1.0f;
    [Range(0.0f, 50.0f)]
    public float depthWeight = 15.0f;
    [Range(0.0f, 100.0f)]
    public float normalWeight = 25.0f;

    private const int PASS_EDGE_COLOR = 0;
    private const int PASS_GAUSSIAN = 1;
    private const int PASS_TEMPORAL = 2;
    private const int PASS_COMPOSITE = 3;
    private const int PASS_COPY = 4;

    void OnEnable()
    {
        if (_shader == null)
        {
            _shader = Resources.Load<Shader>("SSBevel");
            if (_shader == null) { Debug.LogError("SSBevel.shader not found in Resources folder."); return; }
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
                if (data.commandBuffer != null) cam.RemoveCommandBuffer(CameraEvent.BeforeImageEffectsOpaque, data.commandBuffer);
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
            newData.commandBuffer = new CommandBuffer { name = "SS-Bevel" };
            newData.materialInstance = new Material(_shader);
            newData.prevViewProjMatrix = cam.projectionMatrix * cam.worldToCameraMatrix;
            newData.lastPosition = cam.transform.position;
            newData.lastRotation = cam.transform.rotation;
            cam.AddCommandBuffer(CameraEvent.BeforeImageEffectsOpaque, newData.commandBuffer);
            _cameraData.Add(cam, newData);
        }

        var data = _cameraData[cam];
        var cmd = data.commandBuffer;
        var material = data.materialInstance;

        cam.depthTextureMode |= DepthTextureMode.Depth | DepthTextureMode.DepthNormals;
        cmd.Clear();

        int lowResW = (int)(cam.pixelWidth * resolutionScale);
        int lowResH = (int)(cam.pixelHeight * resolutionScale);
        int fullResW = cam.pixelWidth;
        int fullResH = cam.pixelHeight;

        Matrix4x4 projMatrix = GL.GetGPUProjectionMatrix(cam.projectionMatrix, false);
        Matrix4x4 viewMatrix = cam.worldToCameraMatrix;

        // FIX: Set the _InverseView matrix needed by the temporal pass
        material.SetMatrix("_InverseView", viewMatrix.inverse);
        material.SetMatrix("_InverseProjection", projMatrix.inverse);
        material.SetMatrix("_PrevViewProjMatrix", data.prevViewProjMatrix);
        material.SetInt("_SampleCount", sampleCount);
        material.SetFloat("_Radius", radius);
        material.SetFloat("_Sharpness", sharpness);
        material.SetFloat("_DepthThreshold", depthThreshold);
        material.SetFloat("_Intensity", intensity);
        material.SetFloat("_TemporalBlendFactor", temporalBlendFactor);
        material.SetVector("_FullResTexelSize", new Vector4(1.0f / fullResW, 1.0f / fullResH, fullResW, fullResH));
        material.SetFloat("_UseTemporalDithering", useTemporalReprojection ? 1.0f : 0.0f);
        
        RenderTextureFormat format = RenderTextureFormat.DefaultHDR;
        
        int edgeColorID = Shader.PropertyToID("_EdgeColorTex");
        cmd.GetTemporaryRT(edgeColorID, lowResW, lowResH, 0, FilterMode.Point, format);
        cmd.Blit(null, edgeColorID, material, PASS_EDGE_COLOR);
        
        RenderTargetIdentifier filteredResult = edgeColorID;
        if (filterRadius > 0 && filterIterations > 0)
        {
            int upscaledID = Shader.PropertyToID("_UpscaledResult");
            cmd.GetTemporaryRT(upscaledID, fullResW, fullResH, 0, FilterMode.Bilinear, format);
            cmd.Blit(edgeColorID, upscaledID);
            cmd.ReleaseTemporaryRT(edgeColorID);

            int blurBufferID = Shader.PropertyToID("_BlurBuffer");
            cmd.GetTemporaryRT(blurBufferID, fullResW, fullResH, 0, FilterMode.Bilinear, format);

            material.SetFloat("_BlurRadius", filterRadius);
            material.SetFloat("_BlurDepthWeight", depthWeight);
            material.SetFloat("_BlurNormalWeight", normalWeight);

            RenderTargetIdentifier source = upscaledID;
            RenderTargetIdentifier dest = blurBufferID;

            for (int i = 0; i < filterIterations; i++)
            {
                cmd.SetGlobalTexture("_BlurSourceTex", source);
                cmd.Blit(source, dest, material, PASS_GAUSSIAN);
                (source, dest) = (dest, source);
            }
            filteredResult = source;
            cmd.ReleaseTemporaryRT(Shader.PropertyToID(dest.ToString()));
        }

        RenderTargetIdentifier finalResult;
        if (useTemporalReprojection)
        {
            if (data.historyTexture == null || data.historyTexture.width != fullResW || data.historyTexture.height != fullResH)
            {
                if (data.historyTexture != null) data.historyTexture.Release();
                data.historyTexture = new RenderTexture(fullResW, fullResH, 0, format, RenderTextureReadWrite.Linear);
                data.historyTexture.Create();
            }

            int temporalResultID = Shader.PropertyToID("_TemporalResult");
            cmd.GetTemporaryRT(temporalResultID, fullResW, fullResH, 0, FilterMode.Bilinear, format);
            cmd.SetGlobalTexture("_CurrentFrameTex", filteredResult);
            cmd.SetGlobalTexture("_HistoryTex", data.historyTexture);
            cmd.Blit(null, temporalResultID, material, PASS_TEMPORAL);

            cmd.Blit(temporalResultID, data.historyTexture);
            finalResult = new RenderTargetIdentifier(temporalResultID);
        }
        else
        {
            if (data.historyTexture != null) { data.historyTexture.Release(); data.historyTexture = null; }
            finalResult = filteredResult;
        }
        
        cmd.SetGlobalTexture("_AccumulatedBevelTex", finalResult);
        int tempTargetID = Shader.PropertyToID("_TempCameraTarget");
        cmd.GetTemporaryRT(tempTargetID, -1, -1, 0, FilterMode.Point, RenderTextureFormat.DefaultHDR);
        cmd.Blit(BuiltinRenderTextureType.CameraTarget, tempTargetID);

        cmd.SetGlobalTexture("_MainTex", tempTargetID);
        cmd.Blit(tempTargetID, BuiltinRenderTextureType.CameraTarget, material, PASS_COMPOSITE);

        cmd.ReleaseTemporaryRT(tempTargetID);
        
        if (finalResult != filteredResult) cmd.ReleaseTemporaryRT(Shader.PropertyToID(finalResult.ToString()));
        if (filteredResult != edgeColorID) cmd.ReleaseTemporaryRT(Shader.PropertyToID(filteredResult.ToString()));

        data.prevViewProjMatrix = projMatrix * viewMatrix;
        data.lastPosition = cam.transform.position;
        data.lastRotation = cam.transform.rotation;
    }
}