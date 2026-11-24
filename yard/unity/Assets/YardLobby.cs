using System;
using System.Collections.Generic;
using Netcode.Unity;
using UnityEngine;
using Phase = Netcode.Unity.NetcodeYard.Phase;

public sealed class YardLobby : IDisposable
{
    static readonly Color Background = new Color32(14, 26, 34, 255);
    static readonly Color Surface = new Color32(25, 43, 53, 255);
    static readonly Color Input = new Color32(12, 29, 38, 255);
    static readonly Color Foreground = new Color32(228, 239, 240, 255);
    static readonly Color Muted = new Color32(166, 187, 191, 255);
    static readonly Color Accent = new Color32(97, 224, 189, 255);
    static readonly Color Warning = new Color32(255, 205, 130, 255);

    readonly NetcodeYard yard;
    readonly Font font;
    readonly string localIP;
    readonly List<string> chatLines = new List<string>();
    uint[] ports, players = Array.Empty<uint>();
    string hostPort = "", joinIP = "127.0.0.1", joinPort = "", message = "";
    string feedback = "", roomFeedback = "", endpoint = "", chat = "";
    Vector2 scroll;
    GUIStyle title, heading, label, small, button, field, wrapped;

    public YardLobby(NetcodeYard yard)
    {
        this.yard = yard;
        localIP = yard.LocalIP;
        font = Font.CreateDynamicFontFromOSFont(new[] { "Segoe UI", "Microsoft YaHei UI", "Arial" }, 17);
        Randomize();
    }

    public void Update(NetcodeYard.Frame frame)
    {
        if (frame.RoomPhase == Phase.Ended && feedback.Length == 0) feedback = yard.ConnectionStatus;
        if (frame.RoomPhase != Phase.Waiting && frame.RoomPhase != Phase.Connecting) return;
        feedback = "";
        endpoint = yard.Endpoint;
        players = yard.Players();
        chatLines.Clear();
        for (uint index = 0; ; ++index)
        {
            var line = yard.ChatLine(index);
            if (line.Length == 0) break;
            chatLines.Add(line);
        }
        var latest = string.Join("\n", chatLines);
        if (latest == chat) return;
        chat = latest;
        scroll.y = float.MaxValue;
    }

    public void Draw(NetcodeYard.Frame frame)
    {
        EnsureStyles();
        Fill(new Rect(0, 0, Screen.width, Screen.height), Background);
        var scale = Mathf.Min(Screen.width / 960f, Screen.height / 640f);
        var origin = new Vector3((Screen.width - 960 * scale) / 2, (Screen.height - 640 * scale) / 2);
        var matrix = GUI.matrix;
        GUI.matrix = matrix * Matrix4x4.TRS(origin, Quaternion.identity, new Vector3(scale, scale, 1));
        try
        {
            Text(new Rect(48, 33, 400, 28), "CAR YARD  /  UNITY", small, Accent);
            if (frame.RoomPhase == Phase.Setup || frame.RoomPhase == Phase.Ended) DrawSetup();
            else DrawRoom(frame);
        }
        finally { GUI.matrix = matrix; }
    }

    void DrawSetup()
    {
        Text(new Rect(48, 66, 450, 60), "Multiplayer", title, Foreground);
        Fill(new Rect(48, 170, 410, 340), Surface);
        Fill(new Rect(478, 170, 434, 340), Surface);
        Text(new Rect(74, 194, 358, 38), "Join a room", heading, Foreground);
        Text(new Rect(504, 194, 382, 38), "Host a room", heading, Foreground);
        Text(new Rect(74, 249, 358, 28), "Host IPv4", small, Muted);
        joinIP = GUI.TextField(new Rect(74, 281, 358, 40), joinIP, 15, field);
        Text(new Rect(74, 333, 358, 28), "Host port", small, Muted);
        joinPort = GUI.TextField(new Rect(74, 364, 358, 40), joinPort, 5, field);
        Text(new Rect(504, 249, 382, 28), "Local IPv4", small, Muted);
        Fill(new Rect(504, 281, 382, 40), Input);
        Text(new Rect(515, 281, 370, 40), localIP, label, Foreground);
        Text(new Rect(504, 333, 382, 28), "Room port", small, Muted);
        hostPort = GUI.TextField(new Rect(504, 364, 88, 40), hostPort, 5, field);
        for (int index = 0; index < ports.Length; ++index)
        {
            var selected = ports[index].ToString();
            if (Button(new Rect(602 + index * 58, 364, 54, 40), selected)) hostPort = selected;
        }
        if (Button(new Rect(780, 364, 106, 40), "Randomize")) Randomize();
        if (Button(new Rect(74, 439, 358, 45), "Join", true)) Enter(false);
        if (Button(new Rect(504, 439, 382, 45), "Host", true)) Enter(true);
        Text(new Rect(48, 530, 864, 36), feedback, label, Warning);
    }

    void DrawRoom(NetcodeYard.Frame frame)
    {
        bool waiting = frame.RoomPhase == Phase.Waiting;
        bool host = frame.Host != 0;
        Text(new Rect(48, 66, 660, 60), waiting ? (host ? "Hosting room" : "Room") : "Connecting", title, Foreground);
        Text(new Rect(49, 125, 720, 30), endpoint + (waiting ? $"     Room {frame.Room}" : ""), label, Muted);
        if (Button(new Rect(780, 76, 132, 40), waiting ? "Leave room" : "Cancel"))
        {
            yard.Leave();
            feedback = roomFeedback = message = "";
        }
        Fill(new Rect(48, 175, 305, 380), Surface);
        Fill(new Rect(373, 175, 539, 380), Surface);
        Text(new Rect(70, 196, 250, 35), "Players", heading, Foreground);
        Text(new Rect(396, 196, 470, 35), "Room chat", heading, Foreground);
        Text(new Rect(70, 229, 260, 28), waiting ? $"{frame.Seats} / 4 seats" : "Waiting for the host to respond", small, Muted);
        for (int index = 0; index < players.Length; ++index)
        {
            var id = players[index];
            var name = id == 1 ? "Host" : $"Player {id}";
            float y = 274 + index * 46;
            Text(new Rect(70, y, 171, 38), name + (id == frame.Player ? "  (you)" : ""), label, Foreground);
            if (waiting && host && id > 1 && Button(new Rect(249, y, 82, 38), "Kick")) yard.Kick(id);
        }
        if (waiting && host && Button(new Rect(70, 486, 261, 44), "Start game", true))
            yard.Act(NetcodeYard.Action.Start);
        Fill(new Rect(396, 243, 493, 225), Input);
        float chatHeight = Mathf.Max(206, wrapped.CalcHeight(new GUIContent(chat), 451));
        scroll = GUI.BeginScrollView(new Rect(405, 252, 475, 207), scroll, new Rect(0, 0, 451, chatHeight));
        Text(new Rect(0, 0, 451, chatHeight), chat, wrapped, Foreground);
        GUI.EndScrollView();
        if (waiting)
        {
            GUI.SetNextControlName("Room message");
            message = GUI.TextField(new Rect(396, 486, 394, 44), message, 512, field);
            bool submit = Event.current.type == EventType.KeyDown && Event.current.keyCode == KeyCode.Return &&
                          GUI.GetNameOfFocusedControl() == "Room message";
            if (message.Length == 0 && GUI.GetNameOfFocusedControl() != "Room message")
                Text(new Rect(408, 486, 368, 44), "Write a message", label, Muted);
            if (Button(new Rect(802, 486, 87, 44), "Send", true) || submit)
            {
                if (yard.Chat(message.Trim())) message = roomFeedback = "";
                else roomFeedback = "Enter a message of up to 512 UTF-8 bytes.";
                if (submit && Event.current.type != EventType.Used) Event.current.Use();
            }
        }
        Text(new Rect(48, 575, 864, 34), roomFeedback, label, Warning);
    }

    void Enter(bool host)
    {
        try
        {
            yard.Enter(host, joinIP.Trim(), (host ? hostPort : joinPort).Trim());
            feedback = roomFeedback = message = "";
            GUI.FocusControl(null);
        }
        catch (InvalidOperationException error) { feedback = error.Message; }
    }

    void Randomize()
    {
        ports = NetcodeYard.AvailablePorts();
        if (ports.Length != 0) hostPort = ports[0].ToString();
    }

    bool Button(Rect rect, string text, bool primary = false)
    {
        Fill(rect, primary ? new Color32(36, 86, 78, 255) : new Color32(37, 62, 74, 255));
        button.normal.textColor = primary ? Accent : Foreground;
        return GUI.Button(rect, text, button);
    }

    static void Fill(Rect rect, Color color)
    {
        var previous = GUI.color;
        GUI.color = color;
        GUI.DrawTexture(rect, Texture2D.whiteTexture);
        GUI.color = previous;
    }

    static void Text(Rect rect, string text, GUIStyle style, Color color)
    {
        style.normal.textColor = color;
        GUI.Label(rect, text, style);
    }

    void EnsureStyles()
    {
        if (title != null) return;
        label = new GUIStyle(GUI.skin.label) { font = font, fontSize = 17, alignment = TextAnchor.MiddleLeft };
        title = new GUIStyle(label) { fontSize = 42, fontStyle = FontStyle.Bold };
        heading = new GUIStyle(label) { fontSize = 25, fontStyle = FontStyle.Bold };
        small = new GUIStyle(label) { fontSize = 15 };
        wrapped = new GUIStyle(label) { wordWrap = true, alignment = TextAnchor.UpperLeft };
        button = new GUIStyle(label) { alignment = TextAnchor.MiddleCenter };
        button.hover.textColor = Color.white;
        button.active.textColor = Accent;
        field = new GUIStyle(GUI.skin.textField)
        {
            font = font,
            fontSize = 17,
            alignment = TextAnchor.MiddleLeft,
            padding = new RectOffset(12, 12, 0, 0)
        };
    }

    public void Dispose()
    {
        if (font) UnityEngine.Object.Destroy(font);
    }
}
