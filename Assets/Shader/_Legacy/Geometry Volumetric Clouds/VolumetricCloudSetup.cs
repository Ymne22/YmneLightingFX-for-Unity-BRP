using UnityEngine;
using UnityEditor;
using System.Collections.Generic;

[ExecuteInEditMode]
public class VolumetricCloudSetup : MonoBehaviour
{
    [Header("Cloud Settings")]
    public Shader cloudShader;
    public float cloudMinHeight = 1500f;
    public float cloudMaxHeight = 3500f;
    public float volumeSize = 10000f;
    
    [Header("Wind Settings")]
    public Vector3 windDirection = new Vector3(1, 0, 0);
    public float windSpeed = 20f;
    
    [Header("Cloud Properties")]
    public float density = 1.0f;
    public float lightAbsorption = 2.0f;
    public float noiseScale = 1.0f;
    public float coverage = 0.5f;
    // --- ADDED: Control for TAA-friendly noise animation ---
    [Range(0f, 0.1f)]
    public float cloudMorphSpeed = 0.02f;
    public Color cloudColor = new Color(0.9f, 0.9f, 1.0f, 1f);
    public Color sunColor = new Color(1, 0.9f, 0.8f, 1);
    public Color skyColor = new Color(0.4f, 0.6f, 1.0f, 1);
    public Color ambientColor = new Color(0.4f, 0.5f, 0.7f, 1);
    public float detailIntensity = 0.3f;
    public float softness = 0.8f;
    public float hdrExposure = 1.0f;
    public float detailNoiseScale = 5.0f;
    public float curliness = 1.0f;
    public float cloudAttenuation = 0.5f;
    public float silverLiningIntensity = 0.8f;
    public float silverLiningSpread = 0.5f;
    
    [Header("Quality Settings")]
    public int steps = 64;
    public int lightSteps = 6;
    public float maxRaymarchDistance = 1024f;
    [Range(0f, 1f)]
    public float stepSmoothing = 0.5f;

    [Header("References")]
    public Light sunLight;
    public Camera targetCamera;
    
    [Header("Editor Settings")]
    public bool autoUpdateInEditor = true;
    public bool showDebugGizmos = true;
    public float editorIntensityBoost = 1.5f;
    
    [Header("Sky Settings")]
    public bool autoSkyColor = true;
    public Color nightSkyColor = new Color(0.05f, 0.05f, 0.1f, 1f);
    
    private GameObject cloudVolume;
    private Material cloudMaterial;
    
    void Start()
    {
        CreateCloudVolume();
        UpdateMaterialProperties();
        
        if (targetCamera == null)
            targetCamera = Camera.main;
    }
    
    void OnEnable()
    {
        #if UNITY_EDITOR
        if (!Application.isPlaying)
        {
            CreateCloudVolume();
            UpdateMaterialProperties();
        }
        #endif
        
        if (targetCamera == null)
            targetCamera = Camera.main;
    }
    
    void Update()
    {
        #if UNITY_EDITOR
        if (!Application.isPlaying && autoUpdateInEditor)
        {
            UpdateMaterialProperties();
        }
        #endif
        
        if (cloudMaterial != null && Application.isPlaying)
        {
            UpdateMaterialProperties();
        }
    }
    
    public void CreateCloudVolume()
    {
        if (cloudVolume == null)
        {
            cloudVolume = GameObject.Find("VolumetricCloudVolume");
        }
        
        if (cloudVolume == null)
        {
            cloudVolume = GameObject.CreatePrimitive(PrimitiveType.Cube);
            cloudVolume.name = "VolumetricCloudVolume";
            cloudVolume.transform.SetParent(transform);
            DestroyImmediate(cloudVolume.GetComponent<Collider>());
        }
        
        float centerHeight = (cloudMinHeight + cloudMaxHeight) / 2;
        float height = cloudMaxHeight - cloudMinHeight;
        cloudVolume.transform.position = new Vector3(0, centerHeight, 0);
        cloudVolume.transform.localScale = new Vector3(volumeSize, height, volumeSize);
        
        if (cloudShader != null)
        {
            if (cloudMaterial == null || cloudMaterial.shader != cloudShader)
            {
                cloudMaterial = new Material(cloudShader);
            }
            
            Renderer renderer = cloudVolume.GetComponent<Renderer>();
            renderer.sharedMaterial = cloudMaterial;
            renderer.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
            renderer.receiveShadows = false;
        }
    }
    
    public void UpdateMaterialProperties()
    {
        if (cloudMaterial == null) return;
        
        if (sunLight == null)
        {
            Light[] lights = FindObjectsOfType<Light>();
            foreach (Light light in lights)
            {
                if (light.type == LightType.Directional)
                {
                    sunLight = light;
                    break;
                }
            }
            
            if (sunLight == null)
            {
                GameObject lightGO = new GameObject("Directional Light");
                sunLight = lightGO.AddComponent<Light>();
                sunLight.type = LightType.Directional;
            }
        }
        
        cloudMaterial.SetVector("_WindDirection", windDirection.normalized);
        cloudMaterial.SetFloat("_WindSpeed", windSpeed);
        
        cloudMaterial.SetFloat("_CloudMinHeight", cloudMinHeight);
        cloudMaterial.SetFloat("_CloudMaxHeight", cloudMaxHeight);
        cloudMaterial.SetFloat("_VolumeSize", volumeSize);
        cloudMaterial.SetFloat("_EditorIntensity", editorIntensityBoost);
        
        cloudMaterial.SetFloat("_Density", density);
        cloudMaterial.SetFloat("_LightAbsorption", lightAbsorption);
        cloudMaterial.SetFloat("_NoiseScale", noiseScale);
        cloudMaterial.SetFloat("_Coverage", coverage);
        cloudMaterial.SetColor("_CloudColor", cloudColor);
        
        if (sunLight != null)
        {
            float sunIntensity = Mathf.Clamp01(sunLight.intensity);
            Color adjustedSunColor = sunColor * sunIntensity;
            cloudMaterial.SetColor("_SunColor", adjustedSunColor);
            
            if (autoSkyColor)
            {
                Color autoSkyColor = Color.Lerp(nightSkyColor, skyColor, sunIntensity);
                cloudMaterial.SetColor("_SkyColor", autoSkyColor);
            }
            else
            {
                cloudMaterial.SetColor("_SkyColor", skyColor);
            }
        }
        else
        {
            cloudMaterial.SetColor("_SunColor", sunColor);
            cloudMaterial.SetColor("_SkyColor", skyColor);
        }
        
        cloudMaterial.SetColor("_AmbientColor", ambientColor);
        cloudMaterial.SetFloat("_DetailIntensity", detailIntensity);
        cloudMaterial.SetFloat("_Softness", softness);
        cloudMaterial.SetFloat("_HDRExposure", hdrExposure);
        cloudMaterial.SetFloat("_DetailNoiseScale", detailNoiseScale);
        cloudMaterial.SetFloat("_Curliness", curliness);
        cloudMaterial.SetFloat("_CloudAttenuation", cloudAttenuation);
        cloudMaterial.SetFloat("_SilverLiningIntensity", silverLiningIntensity);
        cloudMaterial.SetFloat("_SilverLiningSpread", silverLiningSpread);
        
        // --- MODIFIED: Set new properties on the material ---
        cloudMaterial.SetFloat("_CloudMorphSpeed", cloudMorphSpeed);
        cloudMaterial.SetFloat("_Steps", steps);
        cloudMaterial.SetFloat("_LightSteps", lightSteps);
        cloudMaterial.SetFloat("_MaxDistance", maxRaymarchDistance);
        cloudMaterial.SetFloat("_StepSmoothing", stepSmoothing);
        
        #if UNITY_EDITOR
        if (!Application.isPlaying)
        {
            cloudMaterial.EnableKeyword("_EDITOR_MODE");
        }
        else
        {
            cloudMaterial.DisableKeyword("_EDITOR_MODE");
        }
        #endif
    }
    
    public void OnDisable()
    {
        if (cloudVolume != null)
        {
            DestroyImmediate(cloudVolume);
        }
    }
    
    void OnValidate()
    {
        if (cloudVolume != null)
        {
            float centerHeight = (cloudMinHeight + cloudMaxHeight) / 2;
            float height = cloudMaxHeight - cloudMinHeight;
            cloudVolume.transform.position = new Vector3(0, centerHeight, 0);
            cloudVolume.transform.localScale = new Vector3(volumeSize, height, volumeSize);
            UpdateMaterialProperties();
        }
    }
    
    void OnDrawGizmos()
    {
        if (showDebugGizmos)
        {
            float centerHeight = (cloudMinHeight + cloudMaxHeight) / 2;
            float height = cloudMaxHeight - cloudMinHeight;
            
            Gizmos.color = new Color(0.5f, 0.8f, 1f, 0.3f);
            Gizmos.DrawCube(
                new Vector3(0, centerHeight, 0),
                new Vector3(volumeSize, height, volumeSize)
            );
            
            Gizmos.color = Color.cyan;
            Gizmos.DrawWireCube(
                new Vector3(0, centerHeight, 0),
                new Vector3(volumeSize, height, volumeSize)
            );
            
            Gizmos.color = Color.yellow;
            Vector3 windOrigin = new Vector3(0, centerHeight + height/2, 0);
            Vector3 windTarget = windOrigin + windDirection.normalized * 500f;
            Gizmos.DrawLine(windOrigin, windTarget);
            Gizmos.DrawSphere(windTarget, 50f);
        }
    }
}

#if UNITY_EDITOR
[CustomEditor(typeof(VolumetricCloudSetup))]
public class VolumetricCloudsEditor : Editor
{
    public override void OnInspectorGUI()
    {
        DrawDefaultInspector();
        
        VolumetricCloudSetup setup = (VolumetricCloudSetup)target;
        
        if (GUILayout.Button("Create/Update Cloud Volume"))
        {
            setup.CreateCloudVolume();
            setup.UpdateMaterialProperties();
        }
        
        if (GUILayout.Button("Remove Cloud Volume"))
        {
            setup.OnDisable();
        }
    }
}
#endif