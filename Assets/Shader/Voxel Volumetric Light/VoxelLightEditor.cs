using UnityEngine;
using UnityEditor;

[CustomEditor(typeof(VoxelLight))]
public class VoxelLightEditor : Editor
{
    public override void OnInspectorGUI()
    {
        serializedObject.Update();
        var voxelLight = (VoxelLight)target;

        EditorGUILayout.PropertyField(serializedObject.FindProperty("updateMode"));
        EditorGUILayout.HelpBox("Please use baked mode for better accuracy and performance.", MessageType.Info);
        EditorGUILayout.Space();

        if (voxelLight.updateMode == VoxelLight.UpdateMode.Baked)
        {
            EditorGUILayout.LabelField("Baking Settings", EditorStyles.boldLabel);
            EditorGUILayout.PropertyField(serializedObject.FindProperty("bakeResolution"));
            EditorGUILayout.PropertyField(serializedObject.FindProperty("bakedVoxelData"));
            EditorGUILayout.PropertyField(serializedObject.FindProperty("occluderLayers"));
            EditorGUILayout.PropertyField(serializedObject.FindProperty("falloffExponent"));

            if (voxelLight.bakedVoxelData == null)
            {
                EditorGUILayout.HelpBox("No data baked. Press 'Bake' to generate a Texture3D asset.", MessageType.Warning);
            }

            if (GUILayout.Button("Bake Voxel Data"))
            {
                voxelLight.Bake();
            }

            EditorGUILayout.HelpBox("Voxel baking is CPU-based to make it more accurate. Save before baking!", MessageType.Warning);
        }
        else
        {
            EditorGUILayout.LabelField("Realtime Settings", EditorStyles.boldLabel);
            EditorGUILayout.PropertyField(serializedObject.FindProperty("editorResolution"));
            EditorGUILayout.PropertyField(serializedObject.FindProperty("inGameResolution"));
            EditorGUILayout.PropertyField(serializedObject.FindProperty("showPreviewInEditor"));
            EditorGUILayout.PropertyField(serializedObject.FindProperty("realtimeUpdateMode"));
            if (voxelLight.realtimeUpdateMode == VoxelLight.RealtimeUpdateMode.TimeSliced)
            {
                EditorGUILayout.PropertyField(serializedObject.FindProperty("timeSlicedUpdateRate"));
                EditorGUILayout.PropertyField(serializedObject.FindProperty("slicesPerUpdate"));
            }
            EditorGUILayout.PropertyField(serializedObject.FindProperty("useGPU"));
            if (voxelLight.useGPU)
            {
                EditorGUILayout.HelpBox("GPU mode is fast, but occlusion is less accurate (uses AABBs), Use Vulkan API", MessageType.Info);
            }

            else
            {
                EditorGUILayout.HelpBox("CPU mode is more accurate, but slower.", MessageType.Info);
            }
        }
        
        EditorGUILayout.Space();

        EditorGUILayout.LabelField("Visuals & Quality", EditorStyles.boldLabel);
        DrawPropertiesExcluding(serializedObject, "m_Script", "updateMode", 
            "bakedVoxelData", "bakeResolution", "editorResolution", "inGameResolution", 
            "useGPU", "realtimeUpdateMode", "timeSlicedUpdateRate", "slicesPerUpdate",
            "occluderLayers", "falloffExponent", "showPreviewInEditor");
        
        serializedObject.ApplyModifiedProperties();
    }
}