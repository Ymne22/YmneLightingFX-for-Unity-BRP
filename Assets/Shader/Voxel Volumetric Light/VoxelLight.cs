using UnityEngine;
using UnityEngine.Rendering;
#if UNITY_EDITOR
using UnityEditor;
using UnityEngine.SceneManagement;
using System.IO;
#endif

[ExecuteInEditMode]
[RequireComponent(typeof(Light))]
public class VoxelLight : MonoBehaviour
{
    // --- Enums ---
    public enum UpdateMode { Baked, Realtime }
    public enum RealtimeUpdateMode { EveryFrame, TimeSliced, OnEnable }
    public enum VoxelResolution { _16 = 16, _32 = 32, _64 = 64, _128 = 128, _256 = 256, _512 = 512, _1024 = 1024 }

    // --- Public Fields ---
    [Header("Mode & Resolution")]
    public UpdateMode updateMode = UpdateMode.Realtime;
    [Tooltip("The Texture3D asset containing the baked voxel data.")]
    public Texture3D bakedVoxelData;
    [Tooltip("Resolution of the voxel grid when baking.")]
    public VoxelResolution bakeResolution = VoxelResolution._256;
    [Tooltip("Resolution for the editor's realtime preview.")]
    public VoxelResolution editorResolution = VoxelResolution._64;
    [Tooltip("Resolution for in-game realtime calculations.")]
    public VoxelResolution inGameResolution = VoxelResolution._256;
    [Tooltip("Show the volumetric effect in the editor. Uncheck to hide the effect and its selection outline.")]
    public bool showPreviewInEditor = true;

    [Header("Realtime Behavior")]
    public bool useGPU = true;
    public RealtimeUpdateMode realtimeUpdateMode = RealtimeUpdateMode.EveryFrame;
    public float timeSlicedUpdateRate = 30f;
    public int slicesPerUpdate = 8;
    
    [Header("Visuals")]
    public LayerMask occluderLayers = -1;
    [Range(0.01f, 1f)] public float rangeMultiplier = 1f;
    [Range(0, 10)] public float brightness = 0.65f;
    [Range(0, 5)] public float density = 0.05f;
    [Range(0f, 5f)] public float extinction = 0f;
    [Range(0.5f, 5f)] public float falloffExponent = 2f;
    [Range(-0.95f, 0.95f)] public float anisotropy = -0.6f;
    [Range(0.0f, 10.0f)] public float anisotropySharpness = 0.75f;
    [Range(0f, 32f)] public float proximityBoost = 8f;
    [Range(0.1f, 10f)] public float proximityFalloff = 3f;

    [Header("Quality")]
    [Range(1, 128)] public int raymarchSteps = 12;
    public bool smoothVoxels = true;
    
    [Header("High-Detail Noise")]
    public bool enableNoise = false;
    [Range(0, 1)] public float noiseIntensity = 0.5f;
    public Vector3 noiseScale = new Vector3(1, 1, 1);
    public Vector3 noiseVelocity = new Vector3(0.5f, 0.5f, 0.5f);
    [Range(1, 8)] public int noiseOctaves = 4;
    
    // --- Private Fields ---
    private Light _light;
    private Material _renderMaterial;
    private GameObject _renderVolume;
    private ComputeShader _voxelCompute;
    private float[,,] _voxelData;
    private Texture3D _voxelTexture;
    private Color[] _textureDataBuffer;
    private RenderTexture _voxelRenderTexture;
    private RenderTexture _occRT;
    private ComputeBuffer _boxBuffer;
    private int _kClear, _kBuildOcc, _kLight;
    private const int THREAD = 8;
    private int _boxCount = 0;
    private int _currentUpdateSlice = 0;
    private float _timeSinceLastUpdate = 0f;
    private int _cachedResolution;
    
    // --- Properties ---
    private float EffectiveRange => _light != null ? _light.range * rangeMultiplier : 0f;
    private bool HasValidData => (updateMode == UpdateMode.Baked && bakedVoxelData != null) || (updateMode == UpdateMode.Realtime && (useGPU ? _voxelRenderTexture != null : _voxelTexture != null));
    private int CurrentResolution => (int)(Application.isPlaying ? inGameResolution : editorResolution);

    private void OnEnable()
    {
        _light = GetComponent<Light>();
        InitializeAssets();
        if (updateMode == UpdateMode.Baked) LoadBakedData();
        else UpdateVoxelGridImmediate();
    }

    private void OnDisable() => ReleaseResources();

    private void Update()
    {
        if (_renderVolume != null)
        {
            bool shouldBeActive = HasValidData && (Application.isPlaying || showPreviewInEditor);
            if(_renderVolume.activeSelf != shouldBeActive)
                _renderVolume.SetActive(shouldBeActive);
        }

        if (updateMode == UpdateMode.Baked) return;

        if ((useGPU ? _voxelRenderTexture == null : _voxelTexture == null) || _cachedResolution != CurrentResolution)
        {
            InitializeVoxelGrid();
        }

        if (!Application.isPlaying)
        {
            if (showPreviewInEditor) UpdateVoxelGridImmediate();
            return;
        }

        switch (realtimeUpdateMode)
        {
            case RealtimeUpdateMode.EveryFrame: UpdateVoxelGridImmediate(); break;
            case RealtimeUpdateMode.TimeSliced: HandleTimeSlicedUpdate(); break;
        }
    }
    
    private void LateUpdate()
    {
        if (!HasValidData || _light == null || _renderMaterial == null || (!Application.isPlaying && !showPreviewInEditor)) return;
        if (Camera.main != null) Camera.main.depthTextureMode |= DepthTextureMode.Depth;

        _renderVolume.transform.localScale = Vector3.one * EffectiveRange * 2f;

        Texture textureToBind = (updateMode == UpdateMode.Baked) ? (Texture)bakedVoxelData : (useGPU ? (Texture)_voxelRenderTexture : _voxelTexture);
        _renderMaterial.SetTexture("_VoxelTexture", textureToBind);
        
        if (enableNoise) _renderMaterial.EnableKeyword("NOISE_ENABLED"); else _renderMaterial.DisableKeyword("NOISE_ENABLED");
        _renderMaterial.SetVector("_NoiseScale", noiseScale);
        _renderMaterial.SetVector("_NoiseVelocity", noiseVelocity);
        _renderMaterial.SetFloat("_NoiseIntensity", noiseIntensity);
        _renderMaterial.SetInt("_NoiseOctaves", noiseOctaves);
        
        _renderMaterial.SetVector("_LightColor", (Vector4)_light.color * _light.intensity * brightness);
        _renderMaterial.SetVector("_GridParams", new Vector4(EffectiveRange * 2f, density, extinction, 0));
        _renderMaterial.SetVector("_ProximityParams", new Vector4(proximityBoost, proximityFalloff, 0, 0));
        _renderMaterial.SetVector("_AnisotropyParams", new Vector4(anisotropy, anisotropySharpness, 0, 0));
        _renderMaterial.SetVector("_GridCenter", transform.position);
        _renderMaterial.SetInt("_RaymarchSteps", raymarchSteps);
        _renderMaterial.SetFloat("_VoxelTextureRes", textureToBind != null ? textureToBind.width : 0);
        if (smoothVoxels) _renderMaterial.EnableKeyword("SMOOTH_VOXELS"); else _renderMaterial.DisableKeyword("SMOOTH_VOXELS");
    }

    private void HandleTimeSlicedUpdate()
    {
        _timeSinceLastUpdate += Time.deltaTime;
        if (timeSlicedUpdateRate <= 0) return;
        float interval = 1.0f / timeSlicedUpdateRate;
        if (_timeSinceLastUpdate >= interval)
        {
            UpdateVoxelGridSliced();
            _timeSinceLastUpdate -= interval;
        }
    }
    
    public void UpdateVoxelGridImmediate()
    {
        if (updateMode == UpdateMode.Baked || !enabled) return;
        if (useGPU) DispatchVoxelCompute(true);
        else 
        { 
            for (int z = 0; z < CurrentResolution; z++) CalculateVoxelSlice(z);
            ApplyDataToTexture();
        }
    }

    private void UpdateVoxelGridSliced()
    {
        if (updateMode == UpdateMode.Baked) return;
        if (useGPU) DispatchVoxelCompute(false);
        else
        {
            CalculateVoxelSlice(_currentUpdateSlice);
            ApplyDataToTexture();
        }
        _currentUpdateSlice = (_currentUpdateSlice + 1) % CurrentResolution;
    }
    
    private void LoadBakedData()
    {
        if (bakedVoxelData == null) Debug.LogWarning($"VoxelLight '{name}' is in Baked mode but has no data assigned.", this);
    }
    
#if UNITY_EDITOR
    private void OnValidate()
    {
        if (enabled && gameObject.activeInHierarchy && updateMode == UpdateMode.Realtime && realtimeUpdateMode == RealtimeUpdateMode.OnEnable)
        {
            UnityEditor.EditorApplication.delayCall += UpdateVoxelGridImmediate;
        }
    }

    public void Bake()
    {
        if (_light == null) _light = GetComponent<Light>();
        int resolution = (int)bakeResolution;
        Debug.Log($"Baking Voxel Light for '{name}' at {resolution}x{resolution}x{resolution}...", this);

        var colorData = new Color[resolution * resolution * resolution];
        
        for (int z = 0; z < resolution; z++)
        {
            EditorUtility.DisplayProgressBar("Baking Voxel Light", $"Calculating slice {z + 1} of {resolution}", (float)z / resolution);
            
            float range = EffectiveRange;
            Vector3 gridOrigin = transform.position - Vector3.one * range;
            float voxelSize = (range * 2f) / resolution;
            float spotAngleCos = Mathf.Cos(_light.spotAngle * 0.5f * Mathf.Deg2Rad);

            for (int y = 0; y < resolution; y++)
            for (int x = 0; x < resolution; x++)
            {
                Vector3 voxelCenter = gridOrigin + new Vector3(x + 0.5f, y + 0.5f, z + 0.5f) * voxelSize;
                Vector3 dirToVoxel = voxelCenter - transform.position;
                float dist = dirToVoxel.magnitude;

                float attenuation = (dist > range || (_light.type == LightType.Spot && Vector3.Dot(dirToVoxel.normalized, transform.forward) < spotAngleCos) || (dist > 0.1f && Physics.Raycast(transform.position, dirToVoxel.normalized, dist, occluderLayers)))
                    ? 0f
                    : Mathf.Pow(1.0f - Mathf.Clamp01(dist / range), falloffExponent);
                
                colorData[z * resolution * resolution + y * resolution + x] = new Color(attenuation, 0, 0, 0);
            }
        }

        var texture = new Texture3D(resolution, resolution, resolution, TextureFormat.RHalf, false)
        {
            wrapMode = TextureWrapMode.Clamp,
            filterMode = FilterMode.Trilinear
        };
        texture.SetPixels(colorData);
        texture.Apply(true, true);

        // ---Baked data asset management ---

        string scenePath = gameObject.scene.path;  
        string sceneDir = Path.GetDirectoryName(scenePath);  
        string sceneName = Path.GetFileNameWithoutExtension(scenePath);

        string lightingFolder = Path.Combine(sceneDir, sceneName + "_VoxelLightingData");

        if (!Directory.Exists(lightingFolder))
            Directory.CreateDirectory(lightingFolder);

        string assetPath = Path.Combine(lightingFolder, $"VoxelLight-{name}-{GUID.Generate()}.asset");

        assetPath = assetPath.Replace("\\", "/");
        if (!assetPath.StartsWith("Assets"))
        {
            assetPath = "Assets" + assetPath.Substring(Application.dataPath.Length);
        }

        AssetDatabase.CreateAsset(texture, assetPath);
        AssetDatabase.SaveAssets();
        AssetDatabase.Refresh();

        Undo.RecordObject(this, "Link Baked Voxel Data");
        bakedVoxelData = texture;
        EditorUtility.SetDirty(this);
        EditorUtility.ClearProgressBar();
        Debug.Log($"Bake complete! Data saved to {assetPath}", bakedVoxelData);
    }

    // --- Menu Items for Point & Spot ---
    [MenuItem("GameObject/YmneFX/Voxel Light (Point)", false, 11)]
    static void CreateVoxelPointLight(MenuCommand menuCommand)
    {
        GameObject go = new GameObject("Voxel Light (Point)");
        Light light = go.AddComponent<Light>();
        light.type = LightType.Point;

        // Default presets for Point
        light.range = 12f;
        light.intensity = 1f;
        light.color = Color.white;

        VoxelLight voxel = go.AddComponent<VoxelLight>();
        voxel.rangeMultiplier = 1f;
        voxel.density = 0.05f;
        voxel.brightness = 1.00f;

        GameObjectUtility.SetParentAndAlign(go, menuCommand.context as GameObject);
        Undo.RegisterCreatedObjectUndo(go, "Create Voxel Light (Point)");
        Selection.activeObject = go;
    }

    [MenuItem("GameObject/YmneFX/Voxel Light (Spot)", false, 12)]
    static void CreateVoxelSpotLight(MenuCommand menuCommand)
    {
        GameObject go = new GameObject("Voxel Light (Spot)");
        Light light = go.AddComponent<Light>();
        light.type = LightType.Spot;

        // Default presets for Spot
        light.range = 20f;
        light.intensity = 1f;
        light.spotAngle = 60f;
        light.color = Color.white;

        VoxelLight voxel = go.AddComponent<VoxelLight>();
        voxel.rangeMultiplier = 1f;
        voxel.density = 0.08f;
        voxel.brightness = 1.5f;

        GameObjectUtility.SetParentAndAlign(go, menuCommand.context as GameObject);
        Undo.RegisterCreatedObjectUndo(go, "Create Voxel Light (Spot)");
        Selection.activeObject = go;
    }
#endif

    private void InitializeAssets()
    {
        Shader shader = Shader.Find("Hidden/VoxelLightShader");
        if(shader == null) { Debug.LogError("Hidden/VoxelLightShader not found!"); return; }
        _renderMaterial = new Material(shader);

        if (_renderVolume == null)
        {
            _renderVolume = GameObject.CreatePrimitive(PrimitiveType.Cube);
            _renderVolume.name = "Voxel Render Volume";
            _renderVolume.GetComponent<MeshRenderer>().sharedMaterial = _renderMaterial;
            DestroyImmediate(_renderVolume.GetComponent<BoxCollider>());
            _renderVolume.transform.SetParent(transform, false);
            _renderVolume.hideFlags = HideFlags.HideInHierarchy | HideFlags.HideInInspector | HideFlags.DontSave | HideFlags.NotEditable;
        }
        
        if(updateMode == UpdateMode.Realtime) InitializeVoxelGrid();
    }
    
    private void ReleaseResources()
    {
        if (_renderVolume != null) DestroyImmediate(_renderVolume);
        if (_renderMaterial != null) DestroyImmediate(_renderMaterial);
        if (_voxelTexture != null) DestroyImmediate(_voxelTexture);
        if (_voxelRenderTexture != null) { _voxelRenderTexture.Release(); DestroyImmediate(_voxelRenderTexture); }
        if (_occRT != null) { _occRT.Release(); DestroyImmediate(_occRT); }
        if (_boxBuffer != null) { _boxBuffer.Release(); _boxBuffer = null; }
    }

    private void InitializeVoxelGrid()
    {
        int res = CurrentResolution;
        if (res <= 0) return;
        _cachedResolution = res;
        _currentUpdateSlice = 0;

        if (useGPU)
        {
            if (_voxelCompute == null) _voxelCompute = Resources.Load<ComputeShader>("VoxelLightGen");
            if (_voxelCompute == null) { Debug.LogError("VoxelLightGen.compute not found in Resources folder!"); return; }

            if (_voxelRenderTexture == null || _voxelRenderTexture.width != res)
            {
                if (_voxelRenderTexture != null) _voxelRenderTexture.Release();
                _voxelRenderTexture = new RenderTexture(res, res, 0, RenderTextureFormat.RHalf) { dimension = TextureDimension.Tex3D, volumeDepth = res, enableRandomWrite = true, wrapMode = TextureWrapMode.Clamp, filterMode = FilterMode.Trilinear };
                _voxelRenderTexture.Create();
            }
            if (_occRT == null || _occRT.width != res)
            {
                if (_occRT != null) _occRT.Release();
                _occRT = new RenderTexture(res, res, 0, RenderTextureFormat.R8) { dimension = TextureDimension.Tex3D, volumeDepth = res, enableRandomWrite = true, wrapMode = TextureWrapMode.Clamp, filterMode = FilterMode.Point };
                _occRT.Create();
            }
            _kClear = _voxelCompute.FindKernel("ClearGrid");
            _kBuildOcc = _voxelCompute.FindKernel("BuildOccupancy");
            _kLight = _voxelCompute.FindKernel("LightVoxelize");
        }
        else
        {
            _voxelData = new float[res, res, res];
            _textureDataBuffer = new Color[res * res * res];
            if (_voxelTexture == null || _voxelTexture.width != res)
            {
                if (_voxelTexture != null) DestroyImmediate(_voxelTexture);
                _voxelTexture = new Texture3D(res, res, res, TextureFormat.RHalf, false) { wrapMode = TextureWrapMode.Clamp, filterMode = FilterMode.Trilinear };
            }
        }
    }
    
    private void ApplyDataToTexture()
    {
        int res = CurrentResolution;
        int index = 0;
        for (int z = 0; z < res; z++)
        for (int y = 0; y < res; y++)
        for (int x = 0; x < res; x++)
            _textureDataBuffer[index++] = new Color(_voxelData[x, y, z], 0, 0, 0);
        _voxelTexture.SetPixels(_textureDataBuffer);
        _voxelTexture.Apply(false);
    }
    
    private void CalculateVoxelSlice(int zSlice)
    {
        int res = CurrentResolution;
        float range = EffectiveRange;
        float gridSize = range * 2f;
        float voxelSize = gridSize / res;
        Vector3 gridOrigin = transform.position - Vector3.one * range;
        float spotAngleCos = Mathf.Cos(_light.spotAngle * 0.5f * Mathf.Deg2Rad);

        for (int x = 0; x < res; x++)
        for (int y = 0; y < res; y++)
        {
            Vector3 voxelCenter = gridOrigin + new Vector3(x + 0.5f, y + 0.5f, zSlice + 0.5f) * voxelSize;
            Vector3 dir = voxelCenter - transform.position;
            float dist = dir.magnitude;
            
            float attenuation = 1.0f;
            if (dist > range) { attenuation = 0; }
            else if (_light.type == LightType.Spot && Vector3.Dot(dir.normalized, transform.forward) < spotAngleCos) { attenuation = 0; }
            else if (dist > 0.1f && Physics.Raycast(transform.position, dir.normalized, dist, occluderLayers)) { attenuation = 0; }
            else { attenuation = Mathf.Pow(1.0f - Mathf.Clamp01(dist / range), falloffExponent); }

            _voxelData[x, y, zSlice] = attenuation;
        }
    }
    
    private void UploadOccluders()
    {
        if (!useGPU || _voxelCompute == null) return;

        var renderers = FindObjectsOfType<MeshRenderer>();
        var boxVecs = new System.Collections.Generic.List<Vector3>();
        foreach (var r in renderers)
        {
            if (((1 << r.gameObject.layer) & occluderLayers.value) == 0) continue;
            Bounds b = r.bounds;
            if (b.Contains(transform.position)) continue;
            boxVecs.Add(b.center); boxVecs.Add(b.extents);
        }

        if (_boxBuffer != null && (_boxBuffer.count != boxVecs.Count || boxVecs.Count == 0)) 
        { 
            _boxBuffer.Release(); _boxBuffer = null; 
        }
        
        if (boxVecs.Count == 0) { _boxCount = 0; return; }

        if(_boxBuffer == null)
            _boxBuffer = new ComputeBuffer(boxVecs.Count, sizeof(float) * 3);
        
        _boxBuffer.SetData(boxVecs.ToArray());
        _boxCount = boxVecs.Count / 2;
    }

    private void DispatchVoxelCompute(bool fullUpdate)
    {
        if (_voxelRenderTexture == null || _voxelCompute == null) return;

        UploadOccluders();
        int res = CurrentResolution;
        float range = EffectiveRange;

        _voxelCompute.SetInts("_Res", res, res, res);
        _voxelCompute.SetVector("_GridCenter", transform.position);
        _voxelCompute.SetFloat("_GridSize", range * 2f);

        int sliceStart = fullUpdate ? 0 : _currentUpdateSlice;
        int sliceCount = fullUpdate ? res : Mathf.Min(slicesPerUpdate, res - sliceStart);
        _voxelCompute.SetInt("_SliceStart", sliceStart);
        
        int groupsX = Mathf.CeilToInt(res / (float)THREAD);
        int groupsY = Mathf.CeilToInt(res / (float)THREAD);
        int groupsZ = Mathf.CeilToInt(sliceCount / (float)THREAD);

        if (_boxCount > 0 && _boxBuffer == null) return;

        _voxelCompute.SetTexture(_kClear, "_Voxel", _voxelRenderTexture);
        _voxelCompute.SetTexture(_kClear, "_Occ", _occRT);
        _voxelCompute.Dispatch(_kClear, groupsX, groupsY, groupsZ);

        _voxelCompute.SetTexture(_kBuildOcc, "_Occ", _occRT);
        _voxelCompute.SetInt("_BoxCount", _boxCount);
        if (_boxCount > 0) _voxelCompute.SetBuffer(_kBuildOcc, "_Boxes", _boxBuffer);
        _voxelCompute.Dispatch(_kBuildOcc, groupsX, groupsY, groupsZ);

        _voxelCompute.SetTexture(_kLight, "_Voxel", _voxelRenderTexture);
        _voxelCompute.SetTexture(_kLight, "_Occ", _occRT);
        _voxelCompute.SetVector("_LightPos", transform.position);
        _voxelCompute.SetVector("_LightDir", transform.forward);
        _voxelCompute.SetFloat("_LightRange", range);
        _voxelCompute.SetFloat("_SpotCos", Mathf.Cos(_light.type == LightType.Spot ? _light.spotAngle * 0.5f * Mathf.Deg2Rad : Mathf.PI));
        _voxelCompute.SetFloat("_FalloffExp", falloffExponent);
        _voxelCompute.SetFloat("_Extinction", extinction);
        _voxelCompute.Dispatch(_kLight, groupsX, groupsY, groupsZ);

        if (!fullUpdate)
        {
            _currentUpdateSlice = (sliceStart + sliceCount) % res;
        }
    }
}
