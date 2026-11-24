using System;
using System.IO;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;

public static class YardBuild
{
    public static void Windows()
    {
        string[] arguments = Environment.GetCommandLineArgs();
        int outputArgument = Array.IndexOf(arguments, "-yardOutput");
        if (outputArgument < 0 || outputArgument + 1 == arguments.Length)
            throw new ArgumentException("Provide -yardOutput <absolute player path>");
        string output = arguments[outputArgument + 1];
        Directory.CreateDirectory(Path.GetDirectoryName(output));

        PlayerSettings.productName = "Netcode Unity Car Yard";
        PlayerSettings.companyName = "Netcode";
        PlayerSettings.defaultScreenWidth = 960;
        PlayerSettings.defaultScreenHeight = 630;
        PlayerSettings.fullScreenMode = FullScreenMode.Windowed;
        PlayerSettings.SetScriptingBackend(NamedBuildTarget.Standalone, ScriptingImplementation.Mono2x);

        CreateMaterial("YardFlat", "Unlit/Color");
        CreateMaterial("YardLit", "Standard");

        var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        var map = new GameObject("PlateRoom");
        var probe = map.AddComponent<Netcode.NetcodeLayoutExporter>();
        probe.Schema = 23; probe.Version = 2; probe.SchemaName = "Mover";
        probe.Fields = new[] {new Netcode.NetcodeLayoutExporter.Binding {Id=1,Target=map.transform,Member="position"}};
        if (probe.BuildText() != "schema 23 2 Mover\nvec3 1 . position\n") throw new InvalidOperationException("Layout export");
        UnityEngine.Object.DestroyImmediate(probe);
        Debug.Log("layout_export_pass schema=23 field=position");
        var anchor = new GameObject("PlateAnchor");
        anchor.transform.SetParent(map.transform,false);
        anchor.transform.localPosition = new Vector3(48,132,0);
        PrefabUtility.SaveAsPrefabAsset(map,"Assets/Resources/PlateRoom.prefab");
        UnityEngine.Object.DestroyImmediate(map);
        new GameObject("Car Yard").AddComponent<YardScene>();
        const string scenePath = "Assets/CarYard.unity";
        if (!EditorSceneManager.SaveScene(scene, scenePath))
            throw new InvalidOperationException("Cannot save Unity car yard scene");
        EditorBuildSettings.scenes = new[] { new EditorBuildSettingsScene(scenePath, true) };
        AssetDatabase.SaveAssets();

        var report = BuildPipeline.BuildPlayer(new[] { scenePath }, output, BuildTarget.StandaloneWindows64,
                                               BuildOptions.None);
        if (report.summary.result != BuildResult.Succeeded)
            throw new InvalidOperationException($"Unity player build failed: {report.summary.result}");
        Debug.Log($"netcode_unity_build_ok output={output}");
    }

    static void CreateMaterial(string name, string shaderName)
    {
        string path = "Assets/Resources/" + name + ".mat";
        if (AssetDatabase.LoadAssetAtPath<Material>(path)) return;
        var shader = Shader.Find(shaderName);
        if (!shader) throw new InvalidOperationException("Missing built-in shader " + shaderName);
        AssetDatabase.CreateAsset(new Material(shader), path);
    }
}
