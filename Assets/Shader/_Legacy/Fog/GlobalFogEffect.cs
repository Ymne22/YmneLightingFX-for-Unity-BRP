using UnityEngine;

[ExecuteAlways]
[RequireComponent(typeof(Camera))]
[ImageEffectAllowedInSceneView]
public class GlobalFogEffect : MonoBehaviour
{
    [Header("General Settings")]
    [Tooltip("The main directional light (Sun/Moon). Will be auto-detected if not assigned.")]
    public Light directionalLight;
    [Tooltip("Controls the transition between day and night fog based on the light's angle. The X-axis is the light's vertical angle (-1 to 1) and the Y-axis is the day/night blend factor (0 for night, 1 for day).")]
    public AnimationCurve dayNightCurve = new AnimationCurve(new Keyframe(-0.2f, 0), new Keyframe(0.2f, 1));
    [Space]
    public float fogStartDistance = 0;
    public float fogHeightStart = 0;
    public float fogHeightEnd = 10;
    [Range(0, 1)] public float fogIntensity = 1.0f;

    [Header("Day Settings")]
    public Color dayFogColor = new Color(0.7f, 0.8f, 1.0f);
    [Range(0.001f, 0.1f)] public float dayFogDensity = 0.02f;
    [Range(0, 10)] public float dayGlowIntensity = 1.0f;
    [Range(8, 128)] public float dayGlowPower = 32.0f;

    [Header("Night Settings")]
    public Color nightFogColor = new Color(0.05f, 0.1f, 0.2f);
    [Range(0.001f, 0.1f)] public float nightFogDensity = 0.05f;
    [Range(0, 10)] public float nightGlowIntensity = 0.5f;
    [Range(8, 128)] public float nightGlowPower = 64.0f;

    private Material fogMaterial;
    private Camera mainCamera;

    void OnEnable()
    {
        mainCamera = GetComponent<Camera>();
        mainCamera.depthTextureMode |= DepthTextureMode.Depth;
        CreateMaterial();
    }

    // This method is called for every frame rendered by the camera.
    // Because of [ExecuteAlways], it runs in the editor as well.
    void OnRenderImage(RenderTexture src, RenderTexture dest)
    {
        if (fogMaterial == null)
        {
            CreateMaterial();
            if (fogMaterial == null)
            {
                Graphics.Blit(src, dest);
                return;
            }
        }

        // --- Auto-detect Directional Light ---
        if (directionalLight == null)
        {
            // RenderSettings.sun is the primary directional light in the scene's Lighting settings.
            directionalLight = RenderSettings.sun;
        }

        // If there's still no light, we can't calculate day/night, so we just render and exit.
        if (directionalLight == null)
        {
            fogMaterial.DisableKeyword("DIRECTIONAL_LIGHT_ON");
            Graphics.Blit(src, dest, fogMaterial);
            return;
        }

        // --- Calculate Day/Night Blend Factor ---
        // Get the light's direction vector.
        Vector3 lightDir = directionalLight.transform.forward;
        // The 'y' component tells us how much the light is pointing up or down.
        // -1 = straight down (midday)
        //  0 = horizon (sunrise/sunset)
        // +1 = straight up (from below)
        float lightY = -lightDir.y; // Invert so that positive is day, negative is night

        // Use the animation curve to evaluate the blend factor. This gives artistic control over the transition.
        float dayNightFactor = dayNightCurve.Evaluate(lightY);


        // --- Interpolate Fog Properties ---
        Color currentFogColor = Color.Lerp(nightFogColor, dayFogColor, dayNightFactor);
        float currentFogDensity = Mathf.Lerp(nightFogDensity, dayFogDensity, dayNightFactor);
        float currentGlowIntensity = Mathf.Lerp(nightGlowIntensity, dayGlowIntensity, dayNightFactor);
        float currentGlowPower = Mathf.Lerp(nightGlowPower, dayGlowPower, dayNightFactor);

        // --- Set Material Properties ---
        fogMaterial.EnableKeyword("DIRECTIONAL_LIGHT_ON");
        fogMaterial.SetColor("_FogColor", currentFogColor);
        fogMaterial.SetFloat("_FogDensity", currentFogDensity);
        fogMaterial.SetFloat("_FogIntensity", fogIntensity);
        fogMaterial.SetFloat("_FogStart", fogStartDistance);
        fogMaterial.SetFloat("_FogHeightStart", fogHeightStart);
        fogMaterial.SetFloat("_FogHeightEnd", fogHeightEnd);

        // Pass light data
        fogMaterial.SetVector("_LightDir", directionalLight.transform.forward);
        fogMaterial.SetColor("_LightColor", directionalLight.color * directionalLight.intensity);
        fogMaterial.SetFloat("_SunGlowIntensity", currentGlowIntensity);
        fogMaterial.SetFloat("_SunGlowPower", currentGlowPower);

        // Apply the effect
        Graphics.Blit(src, dest, fogMaterial);
    }

    void CreateMaterial()
    {
        if (fogMaterial == null)
        {
            Shader shader = Shader.Find("Hidden/GlobalFog");
            if (shader != null && shader.isSupported)
            {
                fogMaterial = new Material(shader);
                fogMaterial.hideFlags = HideFlags.HideAndDontSave;
            }
        }
    }

    void OnDisable()
    {
        if (fogMaterial != null)
        {
            if (Application.isPlaying)
                Destroy(fogMaterial);
            else
                DestroyImmediate(fogMaterial);
        }
    }
}
