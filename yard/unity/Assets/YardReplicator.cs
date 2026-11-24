using System;
using System.Collections.Generic;
using System.Linq;
using UnityEngine;

namespace Netcode.Unity
{
    public sealed class YardReplicator
    {
        const float InterpolationSeconds = 0.10f;
        readonly NetcodeYard yard;
        readonly Func<NetcodeYard.ObjectInfo, GameObject> spawn;
        readonly Action<Transform, string, float> custom;
        readonly Dictionary<uint, NetcodeYard.Field[]> schemas = new Dictionary<uint, NetcodeYard.Field[]>();
        readonly Dictionary<uint, Instance> instances = new Dictionary<uint, Instance>();
        readonly List<uint> removed = new List<uint>();
        readonly float[] read = new float[NetcodeYard.MaxFields];
        readonly object[] typed = new object[NetcodeYard.MaxFields];
        public event Action<Transform, string, object> PropertyApplied;
        ulong round;

        public event Action<uint, uint> Created;
        public event Action<uint, uint> Removed;

        public YardReplicator(NetcodeYard yard, Func<NetcodeYard.ObjectInfo, GameObject> spawn,
                             Action<Transform, string, float> custom)
        {
            this.yard = yard;
            this.spawn = spawn;
            this.custom = custom;
        }

        public void Sync(NetcodeYard.Frame frame, float dt)
        {
            if (round != frame.Round)
            {
                foreach (var pair in instances) Retire(pair.Key, pair.Value);
                instances.Clear();
                round = frame.Round;
            }
            foreach (var instance in instances.Values) instance.Seen = false;
            for (uint index = 0; index < frame.Objects; ++index)
            {
                int count = yard.ReadObject(index, out var info, typed, out int mode, out float publicX);
                for (int i = 0; i < count; ++i)
                    read[i] = typed[i] is float number ? number : typed[i] is bool flag && flag ? 1f : 0f;
                if (!instances.TryGetValue(info.Id, out var instance))
                {
                    if (!schemas.TryGetValue(info.Schema, out var fields))
                    {
                        fields = yard.Bindings(info.Schema);
                        schemas.Add(info.Schema, fields);
                    }
                    if (fields.Length != count) throw new InvalidOperationException("Unity binding layout mismatch");
                    instance = new Instance(spawn(info).transform, info, fields, read);
                    instances.Add(info.Id, instance);
                    Created?.Invoke(info.Id, info.Schema);
                }
                instance.LocalState = info.LocalState != 0;
                instance.Mode = mode;
                instance.PublicX = publicX;
                instance.Accept(info.Revision, read, frame.Host == 0 && !instance.LocalState && mode != 1);
                if (PropertyApplied != null) instance.ApplyProperties(typed, PropertyApplied);
                instance.Paint(dt, typed, custom);
                instance.Seen = true;
            }
            removed.Clear();
            foreach (var pair in instances)
                if (!pair.Value.Seen) removed.Add(pair.Key);
            foreach (var id in removed)
            {
                Retire(id, instances[id]);
                instances.Remove(id);
            }
        }

        void Retire(uint id, Instance instance)
        {
            instance.Root.gameObject.SetActive(false);
            UnityEngine.Object.Destroy(instance.Root.gameObject);
            Removed?.Invoke(id, instance.Schema);
        }

        public Transform Node(uint id) => instances.TryGetValue(id, out var instance) ? instance.Root : null;

        // The shared yard uses Cocos's Z(-angle) × Y × X rotation convention.
        public static Quaternion NetworkRotation(Vector3 angles)
            => Quaternion.AngleAxis(-angles.z, Vector3.forward) *
               Quaternion.AngleAxis(angles.y, Vector3.up) * Quaternion.AngleAxis(angles.x, Vector3.right);

        public bool TrySample(uint id, string path, string field, out float current, out float target)
        {
            current = target = 0;
            return instances.TryGetValue(id, out var instance) && instance.TrySample(path, field, out current, out target);
        }

        public bool UsesLocalState(uint id) => instances.TryGetValue(id, out var instance) && instance.LocalState;
        public int Mode(uint id) => instances.TryGetValue(id, out var instance) ? instance.Mode : 0;
        public float PublicX(uint id) => instances.TryGetValue(id, out var instance) ? instance.PublicX : 0;
        public bool TryBufferedSample(out uint id, out float shown, out float authority)
        {
            foreach (var entry in instances)
            {
                var item = entry.Value;
                if (item.Mode != 1 || !item.TrySample(".", "x", out float sample, out _) ||
                    Mathf.Abs(sample - item.PublicX) < .02f || Mathf.Abs(sample - item.Root.localPosition.x) > .02f) continue;
                id = entry.Key; shown = sample; authority = item.PublicX;
                return true;
            }
            id = 0; shown = authority = 0;
            return false;
        }

        sealed class Instance
        {
            internal readonly Transform Root;
            internal readonly uint Schema;
            internal bool Seen;
            readonly NetcodeYard.Field[] fields;
            readonly NodeBinding[] bindings;
            readonly float[] start, target, shown;
            uint revision;
            internal bool LocalState;
            internal int Mode;
            internal float PublicX;
            float elapsed = InterpolationSeconds;

            internal Instance(Transform root, NetcodeYard.ObjectInfo info, NetcodeYard.Field[] fields, float[] values)
            {
                Root = root;
                Schema = info.Schema;
                revision = info.Revision;
                LocalState = info.LocalState != 0;
                this.fields = fields;
                start = new float[fields.Length];
                target = new float[fields.Length];
                shown = new float[fields.Length];
                Array.Copy(values, target, fields.Length);
                Array.Copy(target, start, fields.Length);
                Array.Copy(target, shown, fields.Length);
                bindings = Enumerable.Range(0, fields.Length).GroupBy(i => fields[i].Path)
                    .Select(group => new NodeBinding(group.Key, group.ToArray())).ToArray();
            }

            internal void Accept(uint updated, float[] values, bool smooth)
            {
                if (revision == updated) return;
                revision = updated;
                Array.Copy(shown, start, shown.Length);
                Array.Copy(values, target, target.Length);
                elapsed = smooth ? 0 : InterpolationSeconds;
            }

            internal void ApplyProperties(object[] values, Action<Transform, string, object> apply)
            {
                for (int i = 0; i < fields.Length; ++i)
                {
                    var field = fields[i];
                    if (field.Transform) continue;
                    var node = field.Path == "." ? Root : Root.Find(field.Path);
                    if (node) apply(node, field.Property, values[i]);
                }
            }

            internal void Paint(float dt, object[] typed, Action<Transform, string, float> custom)
            {
                elapsed = Mathf.Min(elapsed + dt, InterpolationSeconds);
                float alpha = elapsed / InterpolationSeconds;
                for (int i = 0; i < fields.Length; ++i)
                {
                    string property = fields[i].Property;
                    bool angle = property == "angle" || property == "rx" || property == "ry" || property == "rz";
                    shown[i] = !fields[i].Transform || alpha >= 1 ? target[i] :
                        angle ? Mathf.LerpAngle(start[i], target[i], alpha) : Mathf.Lerp(start[i], target[i], alpha);
                }
                foreach (var binding in bindings) binding.Apply(Root, fields, shown, typed, custom);
            }

            internal bool TrySample(string path, string property, out float current, out float value)
            {
                for (int i = 0; i < fields.Length; ++i)
                {
                    if (fields[i].Path != path || fields[i].Property != property) continue;
                    current = shown[i];
                    value = target[i];
                    return true;
                }
                current = value = 0;
                return false;
            }
        }

        sealed class NodeBinding
        {
            readonly string path;
            readonly int[] indices;

            internal NodeBinding(string path, int[] indices)
            {
                this.path = path;
                this.indices = indices;
            }

            internal void Apply(Transform root, NetcodeYard.Field[] fields, float[] values, object[] typed,
                                Action<Transform, string, float> custom)
            {
                var node = path == "." ? root : root.Find(path);
                if (!node) return;
                var position = node.localPosition;
                var euler = node.localEulerAngles;
                var scale = node.localScale;
                bool transforms = false;
                foreach (int index in indices)
                {
                    var field = fields[index];
                    var value = values[index];
                    if (!field.Transform)
                    {
                        if (typed[index] is float || typed[index] is bool) custom(node, field.Property, value);
                        continue;
                    }
                    transforms = true;
                    switch (field.Property)
                    {
                        case "x": position.x = value; break;
                        case "y": position.y = value; break;
                        case "z": position.z = value; break;
                        case "rx": euler.x = value; break;
                        case "ry": euler.y = value; break;
                        case "rz":
                        case "angle": euler.z = value; break;
                        case "sx": scale.x = value; break;
                        case "sy": scale.y = value; break;
                        case "sz": scale.z = value; break;
                    }
                }
                if (!transforms) return;
                node.SetLocalPositionAndRotation(position, NetworkRotation(euler));
                node.localScale = scale;
            }
        }
    }
}
