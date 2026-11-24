using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using UnityEngine;

namespace Netcode.Unity
{
    public sealed class NetcodeYard : IDisposable
    {
        const string Library = "netcode_yard_unity";
        public const int MaxFields = 64;
        IntPtr instance;
        readonly byte[] objectBytes = new byte[1280];
        readonly BinaryReader objectReader;

        public enum Phase { Setup = -1, Connecting, Waiting, Playing, Ended }
        public enum Action { Start = 1, Gate, Place, Remove, Horn, EndRound, EndRoom, Disconnect, Rejoin,
                             Authority1, Authority2, Authority3, CycleDriver }

        [StructLayout(LayoutKind.Sequential)]
        public struct Frame
        {
            public ulong Round, Room;
            public int Status;
            public Phase RoomPhase;
            public int Host, Ready, Rejected, Loss;
            public uint Player, Car, Tick, Seats, Objects;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct ObjectInfo
        {
            public uint Id, Schema, Owner, Revision, LocalState;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct NativeField
        {
            public IntPtr Path, Property;
            public int Transform;
        }

        public readonly struct Field
        {
            public readonly string Path, Property;
            public readonly bool Transform;

            internal Field(string path, string property, bool transform)
            {
                Path = path;
                Property = property;
                Transform = transform;
            }
        }

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        static extern IntPtr ny_create(int count, [In] IntPtr[] arguments,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string assets);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        static extern void ny_destroy(IntPtr yard);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        static extern IntPtr ny_error();
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        static extern int ny_advance(IntPtr yard, out Frame frame);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        static extern IntPtr ny_notice(IntPtr yard);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        static extern IntPtr ny_local_ip(IntPtr yard);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        static extern IntPtr ny_room_text(IntPtr yard, int kind, uint index);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        static extern int ny_players(IntPtr yard, [Out] uint[] values);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        static extern int ny_ports([Out] uint[] values);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        static extern int ny_enter(IntPtr yard, int host, [MarshalAs(UnmanagedType.LPUTF8Str)] string address,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string port);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        static extern int ny_leave(IntPtr yard);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        static extern int ny_chat(IntPtr yard, [MarshalAs(UnmanagedType.LPUTF8Str)] string text);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        static extern int ny_kick(IntPtr yard, uint player);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        static extern int ny_object(IntPtr yard, uint index, out ObjectInfo info, [Out] float[] values, int capacity);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        static extern int ny_object_data(IntPtr yard, uint index, out ObjectInfo info, out int mode,
            out float publicX, [Out] byte[] bytes, int capacity);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        static extern int ny_binding(IntPtr yard, uint schema, uint index, out NativeField field);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        static extern void ny_drive(IntPtr yard, float throttle, float steer);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        static extern int ny_act(IntPtr yard, Action action);

        public NetcodeYard(string[] arguments, string assets)
        {
            objectReader = new BinaryReader(new MemoryStream(objectBytes, false), Encoding.UTF8);
            var pointers = new IntPtr[arguments.Length];
            try
            {
                for (int i = 0; i < pointers.Length; ++i)
                    pointers[i] = Marshal.StringToCoTaskMemUTF8(arguments[i]);
                instance = ny_create(pointers.Length, pointers, assets);
                if (instance == IntPtr.Zero) throw Error();
            }
            finally
            {
                foreach (var pointer in pointers) Marshal.FreeCoTaskMem(pointer);
            }
        }

        public Frame Advance()
        {
            Check(ny_advance(instance, out var frame));
            return frame;
        }

        public int ReadObject(uint index, out ObjectInfo info, float[] values)
            => Check(ny_object(instance, index, out info, values, values.Length));

        public int ReadObject(uint index, out ObjectInfo info, object[] values, out int mode, out float publicX)
        {
            int length = Check(ny_object_data(instance, index, out info, out mode, out publicX, objectBytes, objectBytes.Length));
            var r = objectReader;
            r.BaseStream.Position = 0;
            int count = r.ReadByte();
            if (count > values.Length) throw new InvalidDataException("Object field buffer is too small");
            for (int i = 0; i < count; ++i)
            {
                values[i] = global::Netcode.NetcodeGame.ReadField(r,r.ReadByte());
            }
            if (r.BaseStream.Position != length) throw new InvalidDataException("Invalid typed snapshot length");
            return count;
        }

        public Field[] Bindings(uint schema)
        {
            var fields = new List<Field>();
            for (uint index = 0; Check(ny_binding(instance, schema, index, out var field)) != 0; ++index)
                fields.Add(new Field(Text(field.Path), Text(field.Property), field.Transform != 0));
            return fields.ToArray();
        }

        public string Notice => Text(ny_notice(instance));
        public string LocalIP => Text(ny_local_ip(instance));
        public string Endpoint => Text(ny_room_text(instance, 0, 0));
        public string ConnectionStatus => Text(ny_room_text(instance, 1, 0));
        public string ChatLine(uint index) => Text(ny_room_text(instance, 2, index));
        public uint[] Players()
        {
            var values = new uint[4];
            Array.Resize(ref values, Check(ny_players(instance, values)));
            return values;
        }

        public static uint[] AvailablePorts()
        {
            var values = new uint[3];
            Array.Resize(ref values, Check(ny_ports(values)));
            return values;
        }

        public void Enter(bool host, string address, string port) => Check(ny_enter(instance, host ? 1 : 0, address, port));
        public void Leave() => Check(ny_leave(instance));
        public bool Chat(string text) => Check(ny_chat(instance, text)) != 0;
        public bool Kick(uint player) => Check(ny_kick(instance, player)) != 0;
        public void Drive(float throttle, float steer) => ny_drive(instance, throttle, steer);
        public bool Act(Action action) => Check(ny_act(instance, action)) != 0;

        public void Dispose()
        {
            if (instance == IntPtr.Zero) return;
            ny_destroy(instance);
            objectReader.Dispose();
            instance = IntPtr.Zero;
        }

        static string Text(IntPtr value) => Marshal.PtrToStringUTF8(value) ?? string.Empty;
        static InvalidOperationException Error() => new InvalidOperationException(Text(ny_error()));
        static int Check(int value) => value < 0 ? throw Error() : value;
    }
}
