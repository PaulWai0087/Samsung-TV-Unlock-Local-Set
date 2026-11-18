// These ABI declarations were checked against the user's SHA-pinned DVBISDB library.
// No native TV code is executed while building or running the offline tests.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace QN90BStage1
{
    public sealed class NativeDevice : IDevice
    {
        [DllImport(Policy.FactoryLibrary, CallingConvention = CallingConvention.Cdecl)] static extern int factory_get_data(int uid, out int value);
        [DllImport(Policy.FactoryLibrary, CallingConvention = CallingConvention.Cdecl)] static extern int factory_get_item_with_unique_id(uint uid, IntPtr buffer);
        [DllImport(Policy.FactoryLibrary, CallingConvention = CallingConvention.Cdecl)] static extern int factory_get_item_range(int uid, IntPtr rangeBuffer);
        [DllImport(Policy.FactoryLibrary, CallingConvention = CallingConvention.Cdecl)] static extern int factory_get_localset_enum(out int value);
        [DllImport(Policy.FactoryLibrary, CallingConvention = CallingConvention.Cdecl)] static extern int factory_set_preventing_import(int value);
        [DllImport("libc.so.6", CallingConvention = CallingConvention.Cdecl)] static extern uint geteuid();

        static string Hash(byte[] bytes)
        {
            using (var hash = SHA256.Create()) return BitConverter.ToString(hash.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
        }
        static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
        static string ReadBuildId()
        {
            string text = File.ReadAllText("/etc/tizen-release");
            MatchCollection matches = Regex.Matches(text, @"(?m)^BUILD_ID\s*=\s*[""']?([^\s""']+)");
            Require(matches.Count == 1, "Expected exactly one BUILD_ID in /etc/tizen-release");
            return matches[0].Groups[1].Value;
        }
        static void ReadPins(State state)
        {
            // No factory-library P/Invoke precedes these checks.
            state.BuildId = ReadBuildId();
            Require(state.BuildId == Policy.ExpectedBuild, "Firmware build pin mismatch");
            foreach (var expected in Policy.ExpectedHashes)
            {
                string actual = Hash(File.ReadAllBytes(expected.Key));
                state.EvidenceHashes.Add(expected.Key, actual);
                Require(actual == expected.Value, "Firmware SHA256 pin mismatch: " + expected.Key);
            }
        }
        static void ReadMachineIdentity(State state)
        {
            string id = File.ReadAllText("/etc/machine-id").Trim().ToLowerInvariant();
            Require(Regex.IsMatch(id, "^[a-f0-9]{32}$") && id != new string('0', 32), "Invalid /etc/machine-id");
            state.DeviceToken = Hash(Encoding.UTF8.GetBytes("/etc/machine-id:" + id));
            state.DeviceTokenSource = "/etc/machine-id";
        }
        static string Call(string method, int? value = null)
        {
            string executable = File.Exists("/usr/bin/gdbus") ? "/usr/bin/gdbus" : "/bin/gdbus";
            var start = new ProcessStartInfo(executable) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (string argument in new[] { "call", "--system", "--timeout", "5", "--dest", "org.tizen.tv.factory-service", "--object-path", "/TIFacSerObj", "--method", "org.tizen.tv.factoryservice." + method })
                start.ArgumentList.Add(argument);
            if (value.HasValue) start.ArgumentList.Add(value.Value.ToString(CultureInfo.InvariantCulture));
            using (var process = Process.Start(start))
            {
                var output = process.StandardOutput.ReadToEndAsync();
                var error = process.StandardError.ReadToEndAsync();
                if (!process.WaitForExit(7000))
                {
                    try { process.Kill(); } catch { }
                    throw new TimeoutException(method + " exceeded its timeout");
                }
                string stdout = output.GetAwaiter().GetResult().Trim();
                string stderr = error.GetAwaiter().GetResult().Trim();
                Require(process.ExitCode == 0, method + " failed: " + stderr);
                return stdout;
            }
        }
        static void TryRead(State state, string label, Action work)
        {
            try { work(); }
            catch (Exception e) { state.ReadErrors.Add(label + ": " + e.Message); }
        }
        static Item ReadPreventImport()
        {
            IntPtr itemBuffer = Marshal.AllocHGlobal(4096);
            IntPtr rangeBuffer = Marshal.AllocHGlobal(8);
            try
            {
                Marshal.Copy(new byte[4096], 0, itemBuffer, 4096);
                Marshal.Copy(new byte[8], 0, rangeBuffer, 8);
                Require(factory_get_item_with_unique_id(761, itemBuffer) == 1, "Native UID761 metadata getter failed");
                int tpid = Marshal.ReadInt32(itemBuffer);
                Require(tpid == 140202, "Native UID761 did not resolve to TPID140202");
                Require(factory_get_item_range(761, rangeBuffer) == 1, "Native UID761 range getter failed");
                int minimum = Marshal.ReadInt32(rangeBuffer), maximum = Marshal.ReadInt32(rangeBuffer, 4);
                Require(minimum == 0 && maximum == 13, "UID761 range differs from 0..13");
                int value;
                Require(factory_get_data(761, out value) == 1, "Native UID761 value getter failed");
                object[] payload = VariantReader.SuccessfulPayload(Call("GetItem", tpid));
                Require(payload.Length == 8 && payload[0] is int && (int)payload[0] == tpid && payload[6] is string && payload[7] is string,
                    "Unexpected GetItem layout");
                return new Item { Uid = 761, Tpid = tpid, Name = ((string)payload[7]).Trim(), Display = ((string)payload[6]).Trim(), Value = value, Minimum = minimum, Maximum = maximum };
            }
            finally { Marshal.FreeHGlobal(rangeBuffer); Marshal.FreeHGlobal(itemBuffer); }
        }
        static void ReadLocalSets(State state)
        {
            object[] payload = VariantReader.SuccessfulPayload(Call("GetLocalSetListNo"));
            Require(payload.Length == 2 && payload[0] is int && payload[1] is int, "Unexpected GetLocalSetListNo reply");
            state.MaxStore = (int)payload[0]; state.CurrentStore = (int)payload[1];
            Require(state.MaxStore == 54 && state.CurrentStore >= 0 && state.CurrentStore <= 54, "Unexpected Local Set range");
            TryRead(state, "current Local Set name", () => state.CurrentName = VariantReader.LocalSetName(Call("GetLocalSetStr", state.CurrentStore), false));
            int consecutiveFailures = 0;
            for (int index = 0; index <= state.MaxStore; index++)
            {
                try
                {
                    string name = VariantReader.LocalSetName(Call("GetLocalSetStr", index), true);
                    if (name != null) state.VisibleLocalSets.Add(new LocalOption { Store = index, Name = name });
                    consecutiveFailures = 0;
                }
                catch (Exception e)
                {
                    state.ReadErrors.Add("Local Set index " + index + ": " + e.Message);
                    consecutiveFailures++;
                    if (consecutiveFailures >= 3) { state.ReadErrors.Add("List scan stopped after three consecutive failures"); break; }
                }
            }
        }
        public State Read()
        {
            var state = new State();
            try
            {
                ReadPins(state);
                ReadMachineIdentity(state);
                state.EffectiveUid = geteuid();
                Require(state.EffectiveUid == 0, "Effective UID is not 0");
            }
            catch (Exception e)
            {
                state.ReadErrors.Add("Before native calls: " + e.Message);
                state.WriteGateReason = Engine.CheckState(state);
                return state;
            }
            TryRead(state, "Preventing Import mapping/value/range", () => state.PreventImport = ReadPreventImport());
            TryRead(state, "Local Set global enum", () => {
                int value;
                Require(factory_get_localset_enum(out value) == 1, "Native global-enum getter failed");
                state.GlobalEnum = value;
            });
            TryRead(state, "Local Set list", () => ReadLocalSets(state));
            state.WriteGateReason = Engine.CheckState(state);
            state.ReadyToWrite = state.WriteGateReason.Length == 0;
            return state;
        }
        public int SetPreventImport(int value)
        {
            Require(value == 0 || value == 13, "Only Preventing Import values 0 and 13 are allowed");
            var pins = new State();
            ReadPins(pins);
            Require(geteuid() == 0, "Effective UID is not 0");
            return factory_set_preventing_import(value);
        }
    }
}
