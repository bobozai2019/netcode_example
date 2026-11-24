using System;
using Netcode.Unity;
using Netcode;
using UnityEngine;
using UnityEngine.SceneManagement;

public sealed class PhysicsIslandProbe : MonoBehaviour
{
    sealed class Group
    {
        readonly Rigidbody[] bodies = new Rigidbody[4];
        public readonly PhysicsIsland3D Island;
        readonly Scene scene;

        GameObject Box(Vector3 position, Vector3 size)
        {
            var go = new GameObject("Box");
            SceneManager.MoveGameObjectToScene(go, scene);
            go.transform.position = position;
            go.AddComponent<BoxCollider>().size = size;
            return go;
        }
        public Group(string name)
        {
            scene = SceneManager.CreateScene(name, new CreateSceneParameters(LocalPhysicsMode.Physics3D));
            Island = new PhysicsIsland3D(scene,1f/60);
            Box(new Vector3(0,-.5f,0), new Vector3(20,1,20));
            for (int i=0; i<4; i++) {
                var at = i < 2 ? new Vector3(0,.5f+i,0) : new Vector3(i,1,0);
                bodies[i] = Box(at,Vector3.one).AddComponent<Rigidbody>();
                bodies[i].sleepThreshold = 0;
                Island.Add((uint)i+1,bodies[i]);
            }
            var joint = bodies[3].gameObject.AddComponent<FixedJoint>();
            joint.connectedBody = bodies[2];
            joint.enableCollision = false;
        }
        public void Advance(uint end, bool disturb = false)
        {
            while (Island.Tick < end) Island.Step(tick => {
                if (tick == 41)
                    bodies[3].AddForceAtPosition(Vector3.up*2,bodies[3].position+Vector3.right*.35f,ForceMode.Impulse);
                if (tick == 48) {
                    bodies[1].AddForce(new Vector3(.8f,1.4f,.3f),ForceMode.VelocityChange);
                    bodies[3].AddForceAtPosition(Vector3.up*2,bodies[3].position+Vector3.right*.4f,ForceMode.Impulse);
                    if (disturb) bodies[0].AddForce(Vector3.left*3,ForceMode.VelocityChange);
                }
            });
        }
        public void Close() { SceneManager.UnloadSceneAsync(scene); }
    }

    static float Distance(PhysicsIsland3D.Snapshot a, PhysicsIsland3D.Snapshot b)
    {
        float max=0;
        for (int i=0;i<a.Bodies.Count;i++) max = Mathf.Max(max,Vector3.Distance(a.Bodies[i].Position,b.Bodies[i].Position));
        return max;
    }
    NetcodeGame game;
    bool hosting, sent, received, allowReset;
    void Start()
    {
        try {
            Application.runInBackground=true;
            var args = Environment.GetCommandLineArgs();
            hosting = Array.IndexOf(args,"--puzzle-host") >= 0;
            allowReset = Array.IndexOf(args,"--authority-reset") >= 0;
            int port = int.Parse(args[Array.IndexOf(args,"--port")+1]);
            game = new NetcodeGame(System.IO.File.ReadAllText(System.IO.Path.Combine(Application.streamingAssetsPath,"island.cfg")),hosting,"127.0.0.1",port,2);
            if (!game.RegisterRpc(45,RpcDirection.Server,true,1,room:true)) throw new Exception("RPC registration");
            game.RpcReceived += (id,sender,method,data) => {
                if (hosting && sender==2 && method==45 && data.Length==1 && data[0]==70) {
                    Debug.Log("island_confirmed"); enabled=false; Application.Quit();
                }
            };
            Debug.Log("island_open");
        } catch (Exception e) { Fail(e); }
    }
    void OnDestroy() { game?.Dispose(); }
    void Fail(Exception e) { Debug.LogException(e); enabled=false; Application.Quit(1); }
    void Update()
    {
        try {
            var f=game.Advance();
            if (hosting && !sent && f.Seats==2 && game.Start()) {
                var host = new Group("Authoritative");
                host.Advance(45);
                var cp = host.Island.Capture();
                host.Advance(70);
                if (game.Spawn(1,cp.Fields())!=1 || game.Spawn(1,host.Island.Capture().Fields())!=2)
                    throw new Exception("Could not replicate group checkpoints");
                sent=true;
                host.Close();
            }
            if (hosting || received) return;
            var checkpoint=PhysicsIsland3D.Snapshot.FromFields(game.Read(1,false));
            var live=PhysicsIsland3D.Snapshot.FromFields(game.Read(2,false));
            if (checkpoint==null || live==null) return;
            if (checkpoint.Tick!=45 || live.Tick!=70 || checkpoint.Bodies.Count!=4 || checkpoint.Bodies[3].Velocity.magnitude < .1f) throw new Exception("Wrong checkpoint tick");
            var predicted = new Group("WrongInput");
            predicted.Advance(70,true);
            float before = Distance(live,predicted.Island.Capture());
            var replay = new Group("Replay");
            if (replay.Island.Restore(new PhysicsIsland3D.Snapshot(45,new[]{checkpoint.Bodies[0]})) ||
                !replay.Island.Restore(checkpoint)) throw new Exception("Incomplete or invalid checkpoint accepted");
            replay.Advance(70);
            var corrected = replay.Island.Capture();
            var reference = new Group("IndependentReplay");
            if (!reference.Island.Restore(checkpoint)) throw new Exception("Restore failed");
            reference.Advance(70);
            float cold = Distance(corrected,reference.Island.Capture());
            float after = Distance(live,corrected);
            float gap = Mathf.Abs(Vector3.Distance(corrected.Bodies[2].Position,corrected.Bodies[3].Position)-1);
            bool reset = allowReset && after >= .06f;
            if (reset && !replay.Island.Restore(live)) throw new Exception("Could not restore latest authoritative group");
            float final = reset ? Distance(live,replay.Island.Capture()) : after;
            if (!(before > .1f && final < (reset ? .001f : .06f) && cold < .001f && gap < .025f &&
                  checkpoint.Bodies[1].Position.y - checkpoint.Bodies[0].Position.y > .95f))
                throw new Exception($"Group replay outside tolerance before={before} after={after} cold={cold} gap={gap}");
            Debug.Log($"island_pass bodies=4 checkpoint=45 steps=25 before_mm={1000*before:F2} after_mm={1000*after:F2} cold_mm={1000*cold:F2} joint_mm={1000*gap:F2} reset={(reset?1:0)} final_mm={1000*final:F2}");
            predicted.Close(); replay.Close(); reference.Close();
            if (!game.InvokeRpc(0,45,new byte[]{70})) throw new Exception("Could not confirm replay");
            received=true;
            Invoke(nameof(Finish),1);

        } catch (Exception e) { Fail(e); }
    }
    void Finish() { Application.Quit(0); }
}
