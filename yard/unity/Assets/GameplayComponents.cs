using System;
using System.IO;
using System.Collections.Generic;
using System.Linq;
using UnityEngine;
using Netcode;

public sealed class GameplayComponents : MonoBehaviour {
    public int score;
    public Vector4 weights;
    public Color tint = Color.black;
    public ulong selected;
    public byte[] badge = Array.Empty<byte>();
    public Vector2[] route = Array.Empty<Vector2>();
    public Dictionary<int, int> scores = new Dictionary<int, int>();
    public LinkedList<int> queue = new LinkedList<int>();
    NetcodeGame game;
    NetcodeReplica panel, motion;
    Rigidbody2D body;
    Rigidbody body3;
    NetcodeReplica motion3;
    float nextClaim;
    bool host, seeded, claimed, reported, received, finishing;
    void Start() {
        try {
            Application.runInBackground = true;
            Debug.Log("sdk_build_id=" + NetcodeGame.SdkBuildId);
            var args = Environment.GetCommandLineArgs();
            host = Array.IndexOf(args, "--puzzle-host") >= 0;
            int port = int.Parse(args[Array.IndexOf(args, "--port") + 1]);
            game = new NetcodeGame(
                File.ReadAllText(Path.Combine(Application.streamingAssetsPath, "components.cfg")), host,
                "127.0.0.1", port, 2);
            if (!game.Model(1, new ushort[] { 1 }, Ownership.Transaction) ||
                !game.BindCallable("Report", 71, 2, RpcDirection.Server, true,
                                   (Action<uint, uint, int, string, Vector2>)Report, writer: true) ||
                !game.BindCallable("Done", 72, 0, RpcDirection.Client, true, (Action<uint, uint>)Done,
                                   room: true))
                throw new Exception("setup");
            game.Changed += e => {
                if (e.Kind == EventKind.Request)
                    game.Answer(e, true);
                if(!host && e.Kind==EventKind.Result && e.Object==1 && e.Status!=0) {
                    if(e.Status!=4) throw new Exception("Claim rejected with status "+e.Status);
                    claimed=false;
                    nextClaim=Time.unscaledTime+0.25f;
                }
            };
            panel = gameObject.AddComponent<NetcodeReplica>();
            string[] names = { "score", "weights", "tint", "selected", "badge", "route", "scores", "queue" };
            panel.Fields =
                names
                    .Select((name, i) => new NetcodeLayoutExporter.Binding { Id = i + 1, Target = this,
                                                                             Member = name })
                    .ToArray();
            var moving = new GameObject("MovingBody");
            body = moving.AddComponent<Rigidbody2D>();
            body.gravityScale = 0;
            motion = moving.AddComponent<NetcodeReplica>();
            motion.TeleportDistance = 1;
            var moving3 = new GameObject("MovingBody3D");
            body3 = moving3.AddComponent<Rigidbody>();
            body3.useGravity = false;
            motion3 = moving3.AddComponent<NetcodeReplica>();
            motion3.TeleportDistance = 1;
            if (!panel.Bind(game, 1) || !motion.Bind(game, 2) || !motion3.Bind(game, 3))
                throw new Exception("bind");
            Debug.Log("components_open");
        } catch (Exception e) {
            Fail(e);
        }
    }
    void Fail(Exception e) {
        Debug.LogException(e);
        enabled = false;
        Application.Quit(1);
    }
    void OnDestroy() { game?.Dispose(); }
    void Report(uint sender, uint obj, int total, string label, Vector2 spot) {
        if (!host || sender != 2 || obj != 1 || received || total != 42 || label != "ready" ||
            spot != new Vector2(2, -3))
            throw new Exception("unexpected report");
        received = true;
    }
    void Done(uint sender, uint obj) {
        if (host || sender != 1 || obj != 0 || !reported)
            throw new Exception("unexpected reply");
        Debug.Log("components_pass role=guest score=42 fields=8 body=1 reference=1 typed=1 body3d=1");
        enabled = false;
        Application.Quit();
    }
    void Update() {
        try {
            Tick();
        } catch (Exception e) {
            Fail(e);
        }
    }
    void Tick() {
        var f = game.Advance();
        if (host && f.Round == 0 && f.Seats == 2 && game.Start()) {
            if (game.Spawn(1, new object[] { 0, weights, tint, selected, badge, route, scores, queue }) !=
                    1 ||
                game.Spawn(3, new object[] { Vector2.zero, 0f, Vector2.zero, 0f, false, 0, 0 }) != 2 ||
                game.Spawn(4, new object[] { Vector3.zero, Quaternion.identity, Vector3.zero, Vector3.zero,
                                             false, 0, 0 }) != 3)
                throw new Exception("spawn");
        }
        if (!panel.Initialized || !motion.Initialized || !motion3.Initialized)
            return;
        if (host) {
            if (!seeded) {
                score = 7;
                weights = new Vector4(2, 3, 4, 5);
                tint = new Color(.25f, .5f, .75f, 1);
                selected = motion.Reference;
                badge = new byte[] { 0, 255, 7 };
                route = new[] { new Vector2(2, -3) };
                scores[-3] = 16777219;
                scores[4] = 42;
                foreach (var v in new[] { 5, 5, -1 })
                    queue.AddLast(v);
                body3.position = new Vector3(0, 0, 3);
                motion3.TeleportGeneration++;
                body.position = new Vector2(4, 0);
                motion.TeleportGeneration++;
                seeded = true;
            }
            if (received && score == 42 && !finishing) {
                if (!game.CallTracked("Done", 0, 2, 0))
                    throw new Exception("reply");
                finishing = true;
                Debug.Log("components_pass role=host score=42 fields=8 body=1 reference=1 typed=1 body3d=1");
                Invoke(nameof(Finish), 1);
            }
        } else {
            if (!claimed && Time.unscaledTime>=nextClaim && score == 7 && weights == new Vector4(2, 3, 4, 5) &&
                tint == new Color(.25f, .5f, .75f, 1) &&
                game.ResolveGameObject(selected) == body.gameObject &&
                badge.SequenceEqual(new byte[] { 0, 255, 7 }) &&
                route.SequenceEqual(new[] { new Vector2(2, -3) }) && scores.Count == 2 &&
                scores[-3] == 16777219 && scores[4] == 42 && queue.SequenceEqual(new[] { 5, 5, -1 }) &&
                Mathf.Abs(body.position.x - 4) < .02f && Mathf.Abs(body3.position.z - 3) < .02f) {
                if (game.CallMethod("Report", 1, 42, "ready", new Vector2(2, -3)))
                    throw new Exception("writer gate");
                claimed = game.Claim(1);
            }
            if (claimed && game.Writer(1) == 2) {
                score = 42;
                var fields = game.Read(1, false);
                if (!reported && fields.Length > 0 && (int)fields[0] == 42) {
                    if (game.CallMethod("Report", 1, 42, new string('X', 17), Vector2.zero) ||
                        game.CallMethod("Report", 1, "wrong"))
                        throw new Exception("argument gate");
                    reported = game.CallMethod("Report", 1, 42, "ready", new Vector2(2, -3));
                }
            }
        }
    }
    void Finish() { Application.Quit(); }
}
