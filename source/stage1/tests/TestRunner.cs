// Offline tests link only Core/VariantReader. NativeDevice is not compiled here.
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using QN90BStage1;

static class TestRunner
{
    sealed class FakeDevice : IDevice
    {
        public State Current;
        public List<int> Writes = new List<int>();
        public int Reads;
        public bool Expand = true;
        public Func<FakeDevice, int, int?> OnSet;
        public Action<State, int> OnRead;
        public FakeDevice(State state) { Current = Copy(state); }
        public State Read() { State result = Copy(Current); Reads++; OnRead?.Invoke(result, Reads); return result; }
        public int SetPreventImport(int value)
        {
            Check(value == 0 || value == 13, "Write outside the two allowed import values");
            Writes.Add(value);
            int? intercepted = OnSet?.Invoke(this, value);
            if (intercepted.HasValue) return intercepted.Value;
            Apply(value); return 1;
        }
        public void Apply(int value)
        {
            Current.PreventImport.Value = value; Current.PreventImport.Display = value.ToString();
            Current.VisibleLocalSets = OriginalOptions();
            if (value == 0 && Expand)
            {
                // No Singapore fixture is required for stage 1.
                Current.VisibleLocalSets.Add(new LocalOption { Store = 1, Name = "FIXTURE_A" });
                Current.VisibleLocalSets.Add(new LocalOption { Store = 2, Name = "FIXTURE_B" });
            }
        }
    }
    static int passed, failed;
    static State Copy(State state) => JsonSerializer.Deserialize<State>(JsonSerializer.Serialize(state));
    static List<LocalOption> OriginalOptions() => new List<LocalOption> {
        new LocalOption { Store = 0, Name = "NONE" }, new LocalOption { Store = 43, Name = "CHI_DTV" }
    };
    static State Baseline() => new State {
        EffectiveUid = 0, BuildId = Policy.ExpectedBuild, DeviceToken = new string('b', 64),
        EvidenceHashes = Policy.ExpectedHashes.ToDictionary(x => x.Key, x => x.Value),
        PreventImport = new Item { Uid = 761, Tpid = 140202, Name = "Preventing Import", Display = "13", Value = 13, Minimum = 0, Maximum = 13 },
        MaxStore = 54, CurrentStore = 43, CurrentName = "CHI_DTV", GlobalEnum = 65, VisibleLocalSets = OriginalOptions()
    };
    static FakeDevice Unlocked() { var device = new FakeDevice(Baseline()); device.Apply(0); return device; }
    static void Check(bool test, string message) { if (!test) throw new Exception(message); }
    static void ExpectedWrites(FakeDevice device, params int[] expected)
    {
        Check(device.Writes.SequenceEqual(expected), "Unexpected writes: " + string.Join(",", device.Writes));
    }
    static void Test(string label, Action action)
    {
        try { action(); passed++; Console.WriteLine("PASS " + label); }
        catch (Exception e) { failed++; Console.WriteLine("FAIL " + label + ": " + e.Message); }
    }
    static void Rejects(Action action)
    {
        try { action(); } catch (FormatException) { return; } catch (InvalidOperationException) { return; }
        throw new Exception("Unexpected successful parse");
    }
    public static int Main()
    {
        Test("read13 saves original baseline with zero writes and stable snapshots", () => {
            var device = new FakeDevice(Baseline()); var result = Engine.Read(device);
            Check(result.Success && result.Baseline != null && !result.WriteAttempted, result.Message); ExpectedWrites(device);
            device.Apply(0);
            Check(result.Baseline.PreventImport.Value == 13 && result.Baseline.VisibleLocalSets.Count == 2, "Baseline was aliased");
        });
        Test("read0 is valid but never invents an original13 baseline", () => {
            var device = Unlocked(); var result = Engine.Read(device);
            Check(result.Success && result.Baseline == null && result.State.PreventImport.Value == 0, result.Message); ExpectedWrites(device);
        });
        Test("all fingerprint identity metadata and range failures block every write", () => {
            var changes = new List<Action<State>> {
                s => s.EffectiveUid = 5001, s => s.BuildId = "different-build", s => s.DeviceToken = new string('c',64),
                s => s.DeviceTokenSource = "different-source", s => s.PreventImport.Uid = 760, s => s.PreventImport.Tpid = 140201,
                s => s.PreventImport.Name = "Other", s => s.PreventImport.Maximum = 12, s => s.PreventImport.Display = "12",
                s => s.PreventImport.Value = 7, s => s.CurrentStore = 42, s => s.GlobalEnum = 64,
                s => s.ReadErrors.Add("required getter failed")
            };
            foreach (string path in Policy.ExpectedHashes.Keys) { string key = path; changes.Add(s => s.EvidenceHashes[key] = new string('0', 64)); }
            foreach (var change in changes)
                foreach (string action in new[] { "apply", "restore" })
                {
                    var device = action == "restore" ? Unlocked() : new FakeDevice(Baseline()); change(device.Current);
                    var result = Engine.Execute(device, action, Baseline());
                    Check(!result.Success && !result.WriteAttempted && !result.RollbackAttempted, "Bad state passed gate"); ExpectedWrites(device);
                }
        });
        Test("apply writes0 once preserves LocalSet and accepts expansion without Singapore", () => {
            State baseline = Baseline(); var device = new FakeDevice(baseline); var result = Engine.Execute(device, "apply", baseline);
            Check(result.Success && result.Changed && result.WriteAttempted && !result.RollbackAttempted, result.Message);
            Check(result.Before.PreventImport.Value == 13 && result.State.PreventImport.Value == 0 && result.State.CurrentStore == 43 && result.State.GlobalEnum == 65, "Wrong before/after state");
            Check(baseline.PreventImport.Value == 13, "Original baseline changed"); ExpectedWrites(device, 0);
        });
        Test("apply0 with an expanded list is idempotent", () => {
            var device = Unlocked(); var result = Engine.Execute(device, "apply", Baseline());
            Check(result.Success && !result.Changed && !result.WriteAttempted, result.Message); ExpectedWrites(device);
        });
        Test("no visible expansion restores13 and reports unsuccessful apply", () => {
            var device = new FakeDevice(Baseline()) { Expand = false }; var result = Engine.Execute(device, "apply", Baseline());
            Check(!result.Success && result.RollbackAttempted && result.RollbackSucceeded && !result.Changed && result.State.PreventImport.Value == 13, result.Message);
            ExpectedWrites(device, 0, 13);
        });
        Test("setter failure after partial mutation still restores13", () => {
            var device = new FakeDevice(Baseline());
            device.OnSet = (d, value) => { if (d.Writes.Count != 1) return null; d.Apply(value); return 0; };
            var result = Engine.Execute(device, "apply", Baseline());
            Check(!result.Success && result.WriteAttempted && result.RollbackSucceeded && result.State.PreventImport.Value == 13, result.Message); ExpectedWrites(device, 0, 13);
        });
        Test("setter exception after mutation is journaled and restores13", () => {
            var device = new FakeDevice(Baseline());
            device.OnSet = (d, value) => { if (d.Writes.Count != 1) return null; d.Apply(value); throw new Exception("write ended exceptionally"); };
            var result = Engine.Execute(device, "apply", Baseline());
            Check(!result.Success && result.RollbackSucceeded && result.State.PreventImport.Value == 13, result.Message); ExpectedWrites(device, 0, 13);
        });
        Test("required getter failure after write restores13", () => {
            var device = new FakeDevice(Baseline()); device.OnRead = (s, count) => { if (count == 2) s.ReadErrors.Add("simulated post-write getter failure"); };
            var result = Engine.Execute(device, "apply", Baseline());
            Check(!result.Success && result.RollbackSucceeded && result.State.PreventImport.Value == 13, result.Message); ExpectedWrites(device, 0, 13);
        });
        Test("unexpected LocalSet drift is reported and never written back by stage1", () => {
            var device = new FakeDevice(Baseline());
            device.OnSet = (d, value) => { if (d.Writes.Count != 1) return null; d.Apply(value); d.Current.CurrentStore = 42; d.Current.CurrentName = "OTHER"; d.Current.GlobalEnum = 64; return 1; };
            var result = Engine.Execute(device, "apply", Baseline());
            Check(!result.Success && result.RollbackAttempted && !result.RollbackSucceeded && result.Changed && result.State.CurrentStore == 42 && result.State.PreventImport.Value == 13, result.Message); ExpectedWrites(device, 0, 13);
        });
        Test("restore0 writes13 once and restore13 performs no write", () => {
            var device = Unlocked(); var result = Engine.Execute(device, "restore", Baseline());
            Check(result.Success && result.Changed && result.State.PreventImport.Value == 13, result.Message); ExpectedWrites(device, 13);
            var original = new FakeDevice(Baseline()); result = Engine.Execute(original, "restore", Baseline());
            Check(result.Success && !result.WriteAttempted && !result.Changed, result.Message); ExpectedWrites(original);
        });
        Test("failed restore retries13 and never reverts to0", () => {
            var device = Unlocked();
            device.OnSet = (d, value) => { if (d.Writes.Count != 1) return null; d.Apply(value); return 0; };
            var result = Engine.Execute(device, "restore", Baseline());
            Check(!result.Success && result.RollbackSucceeded && result.Changed && result.State.PreventImport.Value == 13, result.Message); ExpectedWrites(device, 13, 13);
        });
        Test("failed recovery reports fresh actual0 state, never cached13", () => {
            var device = new FakeDevice(Baseline()) { Expand = false }; device.OnSet = (d, value) => d.Writes.Count == 2 ? 0 : (int?)null;
            var result = Engine.Execute(device, "apply", Baseline());
            Check(!result.Success && !result.RollbackSucceeded && result.RollbackAttempted && result.Changed && result.State.PreventImport.Value == 0 && device.Reads == 3, result.Message); ExpectedWrites(device, 0, 13);
        });
        Test("unreadable state after recovery is null and explicitly unverified", () => {
            var device = new FakeDevice(Baseline()); device.OnRead = (s, count) => { if (count >= 2) throw new Exception("read unavailable"); };
            var result = Engine.Execute(device, "apply", Baseline());
            Check(!result.Success && !result.RollbackSucceeded && result.State == null && result.Changed && result.Message.Contains("Latest state could not be read"), result.Message); ExpectedWrites(device, 0, 13);
        });
        Test("observed D-Bus metadata tuple and hidden rc0 entries parse correctly", () => {
            var item = VariantReader.SuccessfulPayload("((140202, 0, 13, 5, 5, byte 0x05, '13', 'Preventing Import'), (1,))");
            Check(item.Length == 8 && (int)item[0] == 140202 && (string)item[6] == "13" && (string)item[7] == "Preventing Import", "GetItem mismatch");
            Check(VariantReader.LocalSetName("(('',), (0,))", true) == null, "Hidden entry must be skipped");
            Check(VariantReader.LocalSetName("(('CHI_DTV',), (1,))", false) == "CHI_DTV", "Current name mismatch");
            Rejects(() => VariantReader.LocalSetName("(('',), (0,))", false));
            Rejects(() => VariantReader.LocalSetName("(('',), (-1,))", true));
            Rejects(() => VariantReader.LocalSetName("(('CHI_DTV',), (0,))", true));
            Rejects(() => VariantReader.SuccessfulPayload("((54, 43), (0,))"));
        });
        Console.WriteLine("RESULT passed=" + passed + " failed=" + failed + "; NativeDevice not linked; no native library or TV call executed.");
        return failed == 0 ? 0 : 1;
    }
}
