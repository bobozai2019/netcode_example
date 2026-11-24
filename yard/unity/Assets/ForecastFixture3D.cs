using System;
using System.IO;
using Netcode;
using UnityEngine;

public sealed class ForecastFixture3D : MonoBehaviour {
    NetcodeGame game;
    readonly ForecastBody3D adapter = new ForecastBody3D();
    Rigidbody body;
    bool host, contact, slept, woke, reported;
    int phase, generation, logged = -1;
    int trajectorySample;
    uint revision;
    double deadline;

    void Start() {
        Application.runInBackground = true;
        var args = Environment.GetCommandLineArgs();
        host = Array.IndexOf(args, "--puzzle-host") >= 0;
        var i = Array.IndexOf(args, "--port");
        var a = Array.IndexOf(args, "--address");
        game = new NetcodeGame(File.ReadAllText(Path.Combine(Application.streamingAssetsPath, "body3d.cfg")),
                               host, a >= 0 ? args[a + 1] : "127.0.0.1",
                               i >= 0 ? int.Parse(args[i + 1]) : 43475, 5);
        body = gameObject.AddComponent<Rigidbody>();
        body.useGravity = false;
        body.angularDamping = 0;
        body.linearDamping = 0;
        gameObject.AddComponent<SphereCollider>().radius = .4f;
        var wall = new GameObject("Wall");
        wall.transform.position = new Vector3(3, 0, 0);
        wall.AddComponent<BoxCollider>().size = new Vector3(.2f, 4, 6);
        Debug.Log("forecast_open engine=unity");
    }
    void OnCollisionEnter(Collision hit) { contact = true; }
    void FixedUpdate() {
        if (game == null)
            return;
        var f = game.Advance();
        if (host && f.Round == 0 && f.Seats >= 3 && game.Start()) {
            body.linearVelocity = new Vector3(3, 0, -.25f);
            game.Spawn(1, adapter.Sample(body, 0, 0));
        }
        if (f.Round == 0)
            return;
        if (host) {
            if (phase == 0 && contact) {
                phase = 1;
                deadline = f.Time + .8;
            } else if (phase == 1 && f.Time >= deadline) {
                body.linearVelocity = Vector3.zero;
                body.angularVelocity = Vector3.zero;
                body.Sleep();
                phase = 2;
                deadline = f.Time + .6;
            } else if (phase == 2 && f.Time >= deadline) {
                body.WakeUp();
                body.position = new Vector3(8, 1, -2);
                body.linearVelocity = new Vector3(.5f, 0, -.2f);
                body.rotation = Quaternion.AngleAxis(-.8f * Mathf.Rad2Deg, Vector3.up);
                body.angularVelocity = new Vector3(0, -.4f, 0);
                ++generation;
                phase = 3;
                deadline = f.Time + .7;
            } else if (phase == 3 && f.Time >= deadline) {
                body.linearVelocity = Vector3.zero;
                body.angularVelocity = Vector3.zero;
                body.Sleep();
                phase = 4;
            }
            game.Submit(1, adapter.Sample(body, generation, phase));
        } else {
            var fields = game.Read(1, false);
            if (fields.Length == 0)
                return;
            uint rev = game.Revision(1, out double time);
            if (rev != revision) {
                adapter.Mode = (int)fields[6] < 2 ? ForecastCorrection.Blend : ForecastCorrection.Force;
                adapter.MaxForecast = .25f;
                adapter.Apply(body, fields, f.Time - time);
                revision = rev;
            }
            phase = (int)fields[6];
        }
        float x = body.position.x;
        if (trajectorySample < 4 && f.Time >= .35 + trajectorySample * .15) {
            Debug.Log($"forecast_point index={trajectorySample} x_mm={(int)(x*1000)}");
            ++trajectorySample;
        }
        if (logged != phase) {
            Debug.Log($"forecast_stage phase={phase} x={x} sleep={body.IsSleeping()} contact={contact}");
            logged = phase;
        }
        if (phase == 2 && body.IsSleeping())
            slept = true;
        if (phase == 3 && x >= 7.8f && !body.IsSleeping() && body.linearVelocity.x > 0)
            woke = true;
        if (!reported && contact && slept && woke && phase == 4 && body.IsSleeping() && x > 8) {
            reported = true;
            Debug.Log(
                $"forecast_pass engine=unity contact=1 slept=1 woke=1 final_mm={(int)(x*1000)} depth_mm={(int)(-body.position.z*1000)} heading_mrad={(int)(-Mathf.DeltaAngle(0,body.rotation.eulerAngles.y)*Mathf.Deg2Rad*1000)}");
        }
    }
    void OnDestroy() { game?.Dispose(); }
}
