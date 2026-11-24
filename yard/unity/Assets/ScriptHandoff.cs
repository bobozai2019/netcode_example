using System;
using System.IO;
using Netcode;
using UnityEngine;

public sealed class ScriptHandoff : MonoBehaviour
{
    NetcodeGame game;
    uint checkpoint, replacement, announcedPlayer;
    bool announced, ackSent, ackReceived, departing;

    void Start()
    {
        try {
            Application.runInBackground = true;
            var args = Environment.GetCommandLineArgs();
            int port = int.Parse(args[Array.IndexOf(args, "--port") + 1]);
            bool host = Array.IndexOf(args, "--puzzle-host") >= 0;
            game = new NetcodeGame(File.ReadAllText(Path.Combine(Application.streamingAssetsPath, "plates.cfg")), host, "127.0.0.1", port, 3);
            if (!game.Model(1, new ushort[] {1}, Ownership.Transaction) ||
                !game.RegisterRpc(44, RpcDirection.Server, true, 1, room:true)) throw new Exception("setup");
            for (uint player = 2; player <= 3; player++)
                if (!game.AddStandby(player, "127.0.0.1", port + (int)player - 1)) throw new Exception("standby");
            game.Changed += e => { if (e.Kind == EventKind.SessionReplaced) replacement = e.Epoch; };
            game.RpcReceived += (obj, sender, method, data) => {
                if (sender == 3 && method == 44 && data.Length == 1 && data[0] == 88) ackReceived = true;
            };
            Debug.Log("handoff_open");
        } catch (Exception e) { Fail(e); }
    }

    void Fail(Exception e) { Debug.LogException(e); enabled = false; Application.Quit(1); }
    void OnDestroy() { game?.Dispose(); }
    void Update() { try { Step(); } catch (Exception e) { Fail(e); } }
    void Step()
    {
        var f = game.Advance();
        if (departing && game.Phase == MigrationPhase.Ended) {
            Debug.Log("handoff_retired"); enabled = false; Application.Quit(); return;
        }
        if (game.Phase != MigrationPhase.Running) return;
        if (f.Player != 0 && announcedPlayer != f.Player) {
            announcedPlayer = f.Player; Debug.Log($"handoff_member player={f.Player}");
        }
        if (game.IsHost && f.Round == 0 && f.Seats == 3 && game.Start())
            if (game.Spawn(1, new object[] {77, "vault", 7}) != 1) throw new Exception("spawn");
        var fields = game.Read(1, false);
        if (fields.Length != 3 || (string)fields[1] != "vault" || (int)fields[2] != 7) return;
        int value = (int)fields[0];
        uint term = game.Term;
        if (term == 1 && value == 77 && !announced) {
            if (f.Player == 2 && game.Armed && game.SavedTick != 0) {
                if (checkpoint == 0) checkpoint = game.SavedTick;
                if (game.SavedTick > checkpoint) { announced = true; Debug.Log($"standby_current tick={game.SavedTick}"); }
            } else if (f.Player == 3) { announced = true; Debug.Log("first_value=77"); }
        }
        if (term != replacement) return;
        if (term == 2 && f.Player == 2 && game.IsHost) {
            if (value == 77 && game.Submit(1, 88, "vault", 7)) Debug.Log("restored=77 written=88");
            if (ackReceived && value == 88 && !game.Submit(1, 89, "vault", 7)) throw new Exception("final write");
            if (ackReceived && (int)game.Read(1, false)[0] == 89 && !departing) departing = game.Handoff();
        } else if (term == 2 && f.Player == 3 && value == 88 && !ackSent) {
            ackSent = game.InvokeRpc(0, 44, new byte[] {88}, token:1);
            if (ackSent) Debug.Log("resumed_rpc=88");
        } else if (term == 3 && f.Player == 3 && game.IsHost && value == 89) {
            if (!game.Submit(1, 90, "vault", 7) || (int)game.Read(1,false)[0] != 90) throw new Exception("last write");
            Debug.Log("restored=89 written=90"); enabled = false; Application.Quit();
        }
    }
}
