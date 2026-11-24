using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Netcode.Unity;
using UnityEngine;
using Action = Netcode.Unity.NetcodeYard.Action;
using Phase = Netcode.Unity.NetcodeYard.Phase;

public sealed class YardScene : MonoBehaviour
{
    const uint Car = 1, Gate = 2, Beacon = 3, Barrier = 4, Load = 5;
    static readonly Color Ink = new Color32(21, 34, 43, 255);
    static readonly Color Teal = new Color32(82, 224, 182, 255);
    static readonly Color Amber = new Color32(253, 174, 99, 255);
    static readonly Color Blue = new Color32(118, 166, 245, 255);
    static readonly Color Steel = new Color32(175, 201, 212, 255);

    NetcodeYard yard;
    YardLobby lobby;
    YardReplicator replicas;
    NetcodeYard.Frame frame = new NetcodeYard.Frame { RoomPhase = Phase.Setup, Status = -1 };
    Transform stage;
    Material flat, lit;
    GameObject beaconModel;
    MaterialPropertyBlock paint;
    readonly List<Material> materials = new List<Material>();
    uint beacon;
    string capture = string.Empty;
    string lobbyCapture = string.Empty;
    bool scripted, visualLogged, headingLogged, beaconLogged, captureRequested, captureLogged;
    bool localAuthorityLogged, predictionLogged, profileLogged, profileUpdated;
    Transform profileNode;
    readonly Dictionary<string, object> profile = new Dictionary<string, object>();
    float priorCarX;
    bool lobbyCaptured;
    string failure;

    void Start()
    {
        var processArgs = System.Environment.GetCommandLineArgs();
        if (System.Array.IndexOf(processArgs, "--puzzle-host") >= 0 || System.Array.IndexOf(processArgs, "--puzzle-join") >= 0) {
            enabled = false;
            if (System.Array.IndexOf(processArgs,"--components") >= 0) gameObject.AddComponent<GameplayComponents>();
            else if (System.Array.IndexOf(processArgs,"--script-handoff") >= 0) gameObject.AddComponent<ScriptHandoff>();
            else if (System.Array.IndexOf(processArgs,"--physics-island") >= 0) gameObject.AddComponent<PhysicsIslandProbe>();
            else if (System.Array.IndexOf(processArgs,"--forecast3d") >= 0) gameObject.AddComponent<ForecastFixture3D>();
            else if (System.Array.IndexOf(processArgs,"--forecast") >= 0) gameObject.AddComponent<ForecastFixture>();
            else gameObject.AddComponent<PressurePlates>();
            return;
        }
        try
        {
            Application.runInBackground = true;
            Application.targetFrameRate = 60;
            paint = new MaterialPropertyBlock();
            string[] command = Environment.GetCommandLineArgs();
            int separator = Array.IndexOf(command, "--");
            string[] args = separator >= 0 ? command.Skip(separator + 1).ToArray() : Array.Empty<string>();
            scripted = Array.IndexOf(args, "--scenario") >= 0;
            int captureArg = Array.IndexOf(args, "--capture");
            if (captureArg >= 0 && captureArg + 1 < args.Length) capture = Path.GetFullPath(args[captureArg + 1]);
            int lobbyCaptureArg = Array.IndexOf(args, "--capture-lobby");
            if (lobbyCaptureArg >= 0 && lobbyCaptureArg + 1 < args.Length)
                lobbyCapture = Path.GetFullPath(args[lobbyCaptureArg + 1]);
            flat = Resources.Load<Material>("YardFlat");
            lit = Resources.Load<Material>("YardLit");
            beaconModel = Resources.Load<GameObject>("beacon");
            if (!flat || !lit || !beaconModel) throw new InvalidOperationException("Missing Unity yard assets");
            MakeYard();
            yard = new NetcodeYard(args, Application.streamingAssetsPath);
            if (!scripted) lobby = new YardLobby(yard);
            replicas = new YardReplicator(yard, Spawn, ApplyCustom);
            replicas.PropertyApplied += ApplyTyped;
            replicas.Created += (id, schema) =>
            {
                if (schema == Beacon) beacon = id;
                if (schema == Barrier) Debug.Log($"visual_created object={id}");
            };
            replicas.Removed += (id, schema) =>
            {
                if (schema == Barrier) Debug.Log($"visual_removed object={id}");
                if (schema == Beacon)
                {
                    beacon = 0;
                    beaconLogged = false;
                }
            };
            Debug.Log($"unity_scene_ready version={Application.unityVersion}");
        }
        catch (Exception error) { Fail(error); }
    }

    void Update()
    {
        if (yard == null || failure != null) return;
        try
        {
            if (!scripted) ReadInput();
            frame = yard.Advance();
            lobby?.Update(frame);
            if (lobby != null && !lobbyCaptured && lobbyCapture.Length != 0 &&
                (frame.RoomPhase == Phase.Setup || frame.RoomPhase == Phase.Waiting))
            {
                lobbyCaptured = true;
                StartCoroutine(CaptureFrame(lobbyCapture, "lobby_capture"));
            }
            replicas.Sync(frame, Time.unscaledDeltaTime);
            Observe();
            if (frame.Status >= 0 && (!captureRequested || captureLogged)) Application.Quit(frame.Status);
        }
        catch (Exception error) { Fail(error); }
    }

    void Fail(Exception error)
    {
        failure = error.Message;
        Debug.LogException(error);
        Application.Quit(1);
    }

    void OnDestroy()
    {
        lobby?.Dispose();
        yard?.Dispose();
        foreach (var material in materials) Destroy(material);
    }

    void ReadInput()
    {
        if (Input.GetKeyDown(KeyCode.F2)) yard.Act(Action.Start);
        if (Input.GetKeyDown(KeyCode.R)) yard.Act(Action.Rejoin);
        if (frame.RoomPhase != Phase.Playing) return;
        bool Pressed(KeyCode a, KeyCode b) => Input.GetKey(a) || Input.GetKey(b);
        float throttle = (Pressed(KeyCode.W, KeyCode.UpArrow) ? 1 : 0) -
                         (Pressed(KeyCode.S, KeyCode.DownArrow) ? 1 : 0);
        float steer = (Pressed(KeyCode.D, KeyCode.RightArrow) ? 1 : 0) -
                      (Pressed(KeyCode.A, KeyCode.LeftArrow) ? 1 : 0);
        yard.Drive(throttle, steer);
        if (Input.GetKeyDown(KeyCode.F3)) yard.Act(Action.EndRound);
        if (Input.GetKeyDown(KeyCode.F4)) yard.Act(Action.Disconnect);
        if (frame.Host != 0)
        {
            if (Input.GetKeyDown(KeyCode.F5)) yard.Act(Action.Authority1);
            if (Input.GetKeyDown(KeyCode.F6)) yard.Act(Action.Authority2);
            if (Input.GetKeyDown(KeyCode.F7)) yard.Act(Action.Authority3);
            if (Input.GetKeyDown(KeyCode.F8)) yard.Act(Action.CycleDriver);
        }
        if (Input.GetKeyDown(KeyCode.Q) && frame.Host != 0) yard.Act(Action.EndRoom);
        if (Input.GetKeyDown(KeyCode.E)) yard.Act(Action.Gate);
        if (Input.GetKeyDown(KeyCode.B)) yard.Act(Action.Place);
        if (Input.GetKeyDown(KeyCode.X)) yard.Act(Action.Remove);
        if (Input.GetKeyDown(KeyCode.H)) yard.Act(Action.Horn);
    }

    void MakeYard()
    {
        stage = new GameObject("Network objects").transform;
        var camera = new GameObject("Main Camera").AddComponent<Camera>();
        camera.tag = "MainCamera";
        camera.orthographic = true;
        camera.orthographicSize = 315;
        camera.clearFlags = CameraClearFlags.SolidColor;
        camera.backgroundColor = Ink;
        camera.transform.position = new Vector3(480, 315, -520);
        camera.farClipPlane = 1400;
        var sun = new GameObject("Beacon key light").AddComponent<Light>();
        sun.type = LightType.Directional;
        sun.transform.rotation = Quaternion.Euler(31, -25, 0);
        sun.intensity = 1.3f;
        RenderSettings.ambientLight = new Color(.58f, .64f, .68f);

        var ground = new GameObject("Yard layout").transform;
        Box(ground, "Concrete", new Vector3(480, 299, 65), new Vector3(892, 515, 1), new Color32(31, 48, 59, 255));
        Box(ground, "Drive lane", new Vector3(477, 287, 62), new Vector3(855, 138, 1), new Color32(54, 68, 74, 255));
        Box(ground, "Parking", new Vector3(160, 471, 61), new Vector3(208, 116, 1), new Color32(34, 76, 76, 255));
        Box(ground, "Beacon pad", new Vector3(703, 443, 60), new Vector3(226, 147, 1), new Color32(38, 65, 77, 255));
        for (int x = 76; x < 890; x += 45)
            Box(ground, "Lane marking", new Vector3(x, 287, 59), new Vector3(23, 2, 1), new Color32(149, 152, 124, 255));
        for (int x = 79; x <= 244; x += 41)
            Box(ground, "Parking marking", new Vector3(x, 463, 58), new Vector3(2, 84, 1), new Color32(89, 139, 139, 255));
    }

    GameObject Spawn(NetcodeYard.ObjectInfo info)
    {
        var instance = new GameObject($"Object {info.Id} ({info.Schema})");
        var root = instance.transform;
        root.SetParent(stage, false);
        switch (info.Schema)
        {
            case Car:
                Color body = info.Owner == frame.Player ? Teal : info.Owner == 1 ? Amber : Blue;
                Box(root, "body", Vector3.zero, new Vector3(44, 19, 4), body);
                Box(root, "cab", new Vector3(-4, 0, -3), new Vector3(15, 13, 2), Ink);
                var lamp = new GameObject("lamp").transform;
                lamp.SetParent(root, false);
                Box(lamp, "upper light", new Vector3(19, 5, -3), new Vector3(5, 4, 1), Color.white);
                Box(lamp, "lower light", new Vector3(19, -5, -3), new Vector3(5, 4, 1), Color.white);
                break;
            case Gate:
                Box(root, "body", Vector3.zero, new Vector3(12, 130, 4), Amber);
                for (int y = -57; y < 62; y += 18)
                    Box(root, "stripe", new Vector3(0, y, -3), new Vector3(12, 4, 1), Ink);
                break;
            case Beacon:
                var model = Instantiate(beaconModel, root, false);
                model.name = "model";
                foreach (var renderer in model.GetComponentsInChildren<Renderer>())
                    renderer.sharedMaterial = Material(lit, new Color32(178, 147, 252, 255));
                break;
            case Barrier:
                Box(root, "body", Vector3.zero, new Vector3(36, 26, 7), Steel);
                Box(root, "stripe", new Vector3(0, 0, -5), new Vector3(31, 4, 1), Ink)
                    .transform.localRotation = Quaternion.Euler(0, 0, 26);
                break;
            case Load:
                Box(root, "body", Vector3.zero, new Vector3(10, 10, 4), Steel);
                break;
            case 6: profileNode = root; break;
            default:
                throw new InvalidOperationException($"Unknown yard schema {info.Schema}");
        }
        return instance;
    }

    GameObject Box(Transform parent, string name, Vector3 position, Vector3 scale, Color color)
    {
        var piece = GameObject.CreatePrimitive(PrimitiveType.Cube);
        piece.name = name;
        piece.transform.SetParent(parent, false);
        piece.transform.localPosition = position;
        piece.transform.localScale = scale;
        Destroy(piece.GetComponent<Collider>());
        piece.GetComponent<Renderer>().sharedMaterial = Material(flat, color);
        return piece;
    }

    Material Material(Material template, Color color)
    {
        foreach (var material in materials)
            if (material.shader == template.shader && material.color == color) return material;
        var created = new Material(template) { color = color };
        materials.Add(created);
        return created;
    }

    void ApplyTyped(Transform node, string field, object value)
    {
        if (node != profileNode) return;
        profile[field] = value;
        if (field == "player_name") node.name = (string)value;
        if (!profileLogged && profile.Count == 7 && node.name == "玩家🚀" && (int)profile["score"] == 16777217 &&
            (Vector2)profile["cursor"] == new Vector2(2,-3) && (Vector3)profile["axis"] == new Vector3(4,5,-6) &&
            ((Quaternion)profile["orientation"]).Equals(new Quaternion(0,0,1,0)) &&
            ((int[])profile["inventory"]).SequenceEqual(new[]{7,-2,16777219}) &&
            ((float[])profile["weights"]).SequenceEqual(new[]{.25f,-.5f})) {
            profileLogged = true;
            Debug.Log("typed_profile applied");
        }
        if (!profileUpdated && profile.Count == 7 && node.name == "通关" && (int)profile["score"] == 16777219 &&
            ((int[])profile["inventory"]).SequenceEqual(new[]{7}) && ((float[])profile["weights"]).Length == 0) {
            profileUpdated = true;
            Debug.Log("typed_profile updated");
        }
    }

    void ApplyCustom(Transform node, string field, float value)
    {
        if (field == "glow")
        {
            foreach (Transform lamp in node) SetColor(lamp.GetComponent<Renderer>(), Color.Lerp(Ink, Color.white, .35f + .65f * value));
        }
        else if (field == "is_open")
        {
            SetColor(node.Find("body").GetComponent<Renderer>(), value > .5f ? Teal : Amber);
        }
        else if (field == "net_input_x")
        {
            var body = node.Find("body").GetComponent<Renderer>();
            SetColor(body, Color.Lerp(body.sharedMaterial.color, Color.white, .15f * Mathf.Abs(value)));
        }
        else if (field == "marker")
        {
            var model = node.Find("model");
            if (model)
            {
                foreach (var renderer in model.GetComponentsInChildren<Renderer>())
                    SetColor(renderer, Color.Lerp(new Color32(151, 118, 246, 255), Teal, .25f * Mathf.Abs(value)));
            }
        }
    }

    void SetColor(Renderer renderer, Color color)
    {
        paint.SetColor("_Color", color);
        renderer.SetPropertyBlock(paint);
    }

    void Observe()
    {
        if (frame.Ready == 0 || frame.Tick <= 20) return;
        if (replicas.TrySample(frame.Car, ".", "x", out var shownX, out var targetX))
        {
            bool predicted = replicas.Mode(frame.Car) == 2;
            if (!(predicted ? predictionLogged : localAuthorityLogged) && replicas.UsesLocalState(frame.Car) && priorCarX != 0 &&
                Mathf.Abs(shownX - targetX) < .001f && Mathf.Abs(shownX - priorCarX) > .02f &&
                Mathf.Abs(replicas.Node(frame.Car).localPosition.x - shownX) < .001f)
            {
                Debug.Log((predicted ? "visual prediction_local object=" : "visual authority_local object=") + frame.Car);
                if (predicted) predictionLogged = true;
                else localAuthorityLogged = true;
            }
            priorCarX = shownX;
        }
        if (!visualLogged && replicas.TryBufferedSample(out uint bufferedCar, out var position, out var target))
        {
            Debug.Log(FormattableString.Invariant($"visual id={bufferedCar} target={target:F3} display={position:F3}"));
            visualLogged = true;
        }
        if (!headingLogged && replicas.TrySample(frame.Car, ".", "angle", out var angle, out _) &&
            Mathf.Abs(angle) > 2)
        {
            float radians = angle * Mathf.Deg2Rad;
            var expected = new Vector3(Mathf.Cos(radians), -Mathf.Sin(radians), 0);
            if (Vector3.Dot(replicas.Node(frame.Car).right, expected) < .999f)
                throw new InvalidOperationException("Unity car heading disagrees with the shared simulation");
            Debug.Log(FormattableString.Invariant($"unity_heading_applied car={frame.Car} angle={angle:F3}"));
            headingLogged = true;
        }
        if (!beaconLogged && beacon != 0)
        {
            var model = replicas.Node(beacon).Find("model");
            float Field(string name)
            {
                if (!replicas.TrySample(beacon, "model", name, out var current, out _))
                    throw new InvalidOperationException($"Missing beacon field {name}");
                return current;
            }
            var expectedPosition = new Vector3(Field("x"), Field("y"), Field("z"));
            var expectedRotation = YardReplicator.NetworkRotation(new Vector3(Field("rx"), Field("ry"), Field("rz")));
            var expectedScale = new Vector3(Field("sx"), Field("sy"), Field("sz"));
            if ((model.localPosition - expectedPosition).sqrMagnitude > .001f ||
                Quaternion.Angle(model.localRotation, expectedRotation) > .1f ||
                (model.localScale - expectedScale).sqrMagnitude > .001f)
                throw new InvalidOperationException("Shared beacon 3D transform did not bind");
            Debug.Log(FormattableString.Invariant(
                $"unity_beacon_applied id={beacon} x={model.localPosition.x:F3} y={model.localPosition.y:F3} z={model.localPosition.z:F3} rx={Field("rx"):F3} ry={Field("ry"):F3} rz={Field("rz"):F3} sx={model.localScale.x:F3} sy={model.localScale.y:F3} sz={model.localScale.z:F3}"));
            beaconLogged = true;
        }
        if (capture.Length != 0 && !captureRequested)
        {
            captureRequested = true;
            StartCoroutine(CaptureFrame(capture, "render_capture"));
        }
    }

    IEnumerator CaptureFrame(string destination, string message)
    {
        yield return new WaitForEndOfFrame();
        Texture2D snapshot = null;
        try
        {
            snapshot = ScreenCapture.CaptureScreenshotAsTexture();
            if (!snapshot) throw new InvalidOperationException("Unity screen capture returned no pixels");
            File.WriteAllBytes(destination, snapshot.EncodeToPNG());
            if (message == "render_capture") captureLogged = true;
            Debug.Log(message + "_ok");
        }
        catch (Exception error) { Fail(error); }
        finally { if (snapshot) Destroy(snapshot); }
    }

    void OnGUI()
    {
        if (lobby != null && frame.RoomPhase != Phase.Playing && failure == null)
        {
            lobby.Draw(frame);
            return;
        }
        var label = new GUIStyle(GUI.skin.label) { fontSize = 17, normal = { textColor = Steel } };
        var title = new GUIStyle(label) { fontSize = 25, fontStyle = FontStyle.Bold, normal = { textColor = Color.white } };
        GUI.Label(new Rect(24, 14, 400, 40), "CAR YARD / UNITY", title);
        string status = failure ?? (frame.RoomPhase switch
        {
            Phase.Connecting => "Connecting to host",
            Phase.Waiting => $"{frame.Seats}/4 seats   " + (frame.Host != 0 ? "F2  Start" : "Waiting for host"),
            Phase.Playing => frame.Ready != 0 ? $"Player {frame.Player}   ·   Car {frame.Car}   ·   Tick {frame.Tick}" : "Applying current world",
            _ => frame.Host != 0 ? "Room closed" : "Disconnected   R  Reconnect"
        });
        GUI.Label(new Rect(278, 19, Screen.width - 295, 31), status, label);
        GUI.Label(new Rect(26, 48, 700, 29), yard?.Notice ?? string.Empty, label);
        GUI.Label(new Rect(26, Screen.height - 33, Screen.width - 48, 28),
            "WASD / arrows  Drive     E  Gate     B  Place     X  Remove     H  Horn     " +
            (frame.Host != 0 ? "F5-F7  Guest authority    F8  Lend car" : "F4 / R  Reconnect"), label);
    }
}
