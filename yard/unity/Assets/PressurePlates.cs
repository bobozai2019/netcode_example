using System;
using System.IO;
using Netcode;
using UnityEngine;

public sealed class PressurePlates : MonoBehaviour
{
    NetcodeGame game;
    bool host, automatic, wantMove, claimed, submitted, solved;
    readonly System.Collections.Generic.Dictionary<uint,uint> generations = new System.Collections.Generic.Dictionary<uint,uint>();
    readonly System.Collections.Generic.Dictionary<uint,GameObject> rooms = new System.Collections.Generic.Dictionary<uint,GameObject>();
    int mapPhase;
    bool commandSent, inputSent, chargeReported, ackReported;
    int deadline;
    bool clockReported;
    readonly int[] positions = new int[2];
    readonly string[] labels = { "Amber", "Jade" };

    void Start()
    {
        var args = Environment.GetCommandLineArgs();
        host = Array.IndexOf(args, "--puzzle-host") >= 0;
        automatic = Array.IndexOf(args, "--puzzle-auto") >= 0;
        int portArg = Array.IndexOf(args, "--port"), addressArg = Array.IndexOf(args, "--address");
        int port = portArg < 0 ? 43271 : int.Parse(args[portArg + 1]);
        var address = addressArg < 0 ? "127.0.0.1" : args[addressArg + 1];
        Application.runInBackground = true;
        game = new NetcodeGame(File.ReadAllText(Path.Combine(Application.streamingAssetsPath, "plates.cfg")), host, address, port, 5);
        if (!game.Model(1, new ushort[] { 1 }, Ownership.Transaction)) throw new InvalidOperationException("Plate model");
        if (!game.RegisterRpc(31, RpcDirection.Server, true, 1, writer: true)) throw new InvalidOperationException("Plate command");
        if (!game.RegisterPrediction(2, 1, new byte[]{0}, (fields, input, tick) => new object[]{ (int)fields[0] + input[0] }))
            throw new InvalidOperationException("Charge prediction");
        if (host) game.SetPlayerTtl(15000);
        game.RpcOutcome += (token,player,id,method,status) => {
            if (method==31 && status==RpcStatus.Received) Debug.Log($"plate_ack token={token} player={player}");
        };
        game.RpcReceived += (id, sender, method, data) => {
            if (method == 31 && data.Length == 1)
                Debug.Log($"plate_action player={sender} object={id} value={data[0]}");
        };
        game.Changed += e => {
            if (!ackReported && e.Kind == EventKind.Reconciled && e.Object == 3 && e.Sequence == 1) {
                ackReported = true;
                Debug.Log("charge_ack sequence=1");
            }
            if (e.Kind == EventKind.MapAdded && game.MapAsset(e.Object) == "plates") {
                generations[e.Object] = e.Epoch;
                StartCoroutine(MountRoom(e.Object,e.Epoch));
            }
            if (e.Kind == EventKind.MapRemoved) {
                generations.Remove(e.Object);
                if (rooms.TryGetValue(e.Object,out var node)) {
                    node.transform.SetParent(null);
                    Destroy(node);
                    rooms.Remove(e.Object);
                    Debug.Log($"map_removed scene={e.Object} generation={e.Epoch}");
                } else Debug.Log($"map_cancel scene={e.Object} generation={e.Epoch}");
            }
            if (e.Kind == EventKind.Request) game.Answer(e, true);
            if (e.Kind == EventKind.Result && e.Status != 0) claimed = false;
        };
        Debug.Log("puzzle_open engine=unity host=" + (host ? 1 : 0));
    }
    System.Collections.IEnumerator MountRoom(uint scene,uint generation) {
        var request = Resources.LoadAsync<GameObject>("PlateRoom");
        yield return request;
        while (automatic && scene == 2 && generation == 2 && generations.TryGetValue(scene,out uint held) && held == generation)
            yield return null;
        if (!generations.TryGetValue(scene,out uint live) || live != generation) yield break;
        var node = Instantiate((GameObject)request.asset,transform);
        if (!node.transform.Find("PlateAnchor")) throw new InvalidOperationException("Missing plate anchor");
        rooms.Add(scene,node);
        if (!host) game.Loaded(scene,generation);
        Debug.Log($"map_mounted scene={scene} generation={generation} anchors=1");
    }
    void Update()
    {
        if (game == null) return;
        var frame = game.Advance();
        if (host && frame.Round == 0 && frame.Seats >= 3 && game.Start()) {
            game.LoadMap(1, "plates");
            game.Spawn(1, new object[] { 0, "Amber", 3200 }, scene: 1, key: 100);
            game.Spawn(1, new object[] { 0, "Jade", 3200 }, scene: 1, key: 200, mode: Ownership.Dynamic);
            var meter = game.Spawn(2, new object[]{0}, scene:1, key:300);
            game.Distribute(meter, InterestKind.Area, new ulong[]{81});
            foreach (uint member in new uint[]{2,3}) game.Subscribe(member, InterestKind.Area, new ulong[]{81}, new int[]{1});
            game.BindPrediction(meter, 2);
        }
        if (host && automatic && frame.Round != 0) {
            if (mapPhase == 0 && frame.Time > .45) { game.LoadMap(2,"plates"); mapPhase++; }
            else if (mapPhase == 1 && frame.Time > 1.25) { game.UnloadMap(2); game.LoadMap(2,"plates"); mapPhase++; }
            else if (mapPhase == 2 && frame.Time > 2.4) { game.UnloadMap(2); mapPhase++; }
        }
        if (automatic && frame.Player == 2 && !inputSent && game.Predict(3, new byte[]{5})) {
            inputSent = true;
            if ((int)game.PredictedFields(3)[0] == 5) Debug.Log("charge_predicted value=5");
        }
        var charge = game.Read(3,false);
        if (!chargeReported && charge.Length == 1 && (int)charge[0] == 5) {
            chargeReported = true;
            Debug.Log("charge_confirmed value=5");
        }
        for (int i=0; i<positions.Length; ++i) {
            var fields = game.Read(game.FindObject(1, (ulong)(i + 1) * 100), false);
            if (fields.Length != 3) continue;
            deadline=(int)fields[2];
            positions[i] = (int)fields[0]; labels[i] = (string)fields[1];
        }
        if ((automatic || wantMove) && (frame.Player == 2 || frame.Player == 3)) {
            uint id = frame.Player - 1;
            if (game.Writer(id) != frame.Player) { if (!claimed) claimed = game.Claim(id); }
            else if (!submitted) submitted = game.Submit(id, id == 1 ? 3 : 7);
            if (submitted && !commandSent) commandSent = game.InvokeRpc(id, 31, new byte[] { (byte)(id == 1 ? 3 : 7) },token:id);
        }
        if (!clockReported && deadline>0 && frame.Time*1000 >= deadline) {
            clockReported=true; Debug.Log($"countdown_reached deadline_ms={deadline} observed_ms={(int)(frame.Time*1000)}");
        }
        if (!solved && positions[0] == 3 && positions[1] == 7 && labels[0] == "Amber" && labels[1] == "Jade"
            && game.Writer(1) == 2 && game.Writer(2) == 3) {
            solved = true;
            Debug.Log($"puzzle_solved engine=unity player={frame.Player} first={game.Writer(1)} second={game.Writer(2)}");
        }
    }
    void OnGUI()
    {
        GUILayout.BeginArea(new Rect(35,35,600,320));
        GUILayout.Label("Pressure plates");
        for (int i=0; i<2; ++i) {
            GUILayout.BeginHorizontal(); GUILayout.Label(labels[i], GUILayout.Width(70));
            for (int j=0; j<8; ++j) GUILayout.Box(positions[i] == j ? "X" : j == (i==0?3:7) ? "+" : " ", GUILayout.Width(40));
            GUILayout.EndHorizontal();
        }
        if (solved) GUILayout.Label("Both plates aligned");
        else if (host) GUILayout.Label("Waiting for both players");
        else if (GUILayout.Button("Move my plate")) wantMove = true;
        GUILayout.EndArea();
    }
    void OnDestroy() { game?.Dispose(); }
}
