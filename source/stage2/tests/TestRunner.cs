// Only the stage2 state machine/parser are linked; no NativeDevice or TV calls.
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using QN90BStage2;

static class TestRunner
{
    sealed class FakeDevice : IDevice
    {
        public State Current;
        public List<int> Writes = new List<int>();
        public int Reads;
        public Func<FakeDevice, int, int?> OnSet;
        public Action<State, int> OnRead;
        public FakeDevice(State initial) { Current = Copy(initial); }
        public State Read() { var snapshot = Copy(Current); Reads++; OnRead?.Invoke(snapshot, Reads); return snapshot; }
        public int SetLocalSetStore(int store)
        {
            Check(store == 3 || store == 43, "An enum or unauthorized store reached the writer");
            Writes.Add(store);
            int? intercepted = OnSet?.Invoke(this, store);
            if (intercepted.HasValue) return intercepted.Value;
            Apply(store); return 1;
        }
        public void Apply(int store)
        {
            Current.CurrentStore = Current.ConvertedCurrentStore = store;
            Current.GlobalEnum = Current.LocalSet.Value = store == 3 ? 25 : 65;
            Current.CurrentName = Current.LocalSet.Display = store == 3 ? "AD_SIN2" : "CHI_DTV";
            // There is intentionally no Import setter in this fake or the contract.
        }
    }
    static int passed, failed;
    static State Copy(State state) => JsonSerializer.Deserialize<State>(JsonSerializer.Serialize(state));
    static State Baseline()
    {
        var state = new State {
            EffectiveUid = 0, BuildId = Policy.ExpectedBuild, DeviceToken = new string('b', 64),
            EvidenceHashes = Policy.ExpectedHashes.ToDictionary(x => x.Key, x => x.Value),
            PreventImport = new Item { Uid = 761, Tpid = 140202, Name = "Preventing Import", Display = "0", Value = 0, Minimum = 0, Maximum = 13 },
            LocalSet = new Item { Uid = 194, Tpid = 401, Name = "Local Set", Display = "CHI_DTV", Value = 65 },
            MaxStore = 54, CurrentStore = 43, CurrentName = "CHI_DTV", GlobalEnum = 65, ConvertedCurrentStore = 43,
            SingaporeStore = 3, SingaporeName = "AD_SIN2", ChinaStore = 43, ChinaName = "CHI_DTV"
        };
        for (int i = 0; i <= 54; i++) state.VisibleLocalSets.Add(new LocalOption { Store = i, Name = i == 0 ? "NONE" : i == 3 ? "AD_SIN2" : i == 43 ? "CHI_DTV" : "FIXTURE_" + i });
        return state;
    }
    static FakeDevice Singapore() { var device = new FakeDevice(Baseline()); device.Apply(3); return device; }
    static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    static void Writes(FakeDevice device, params int[] expected) => Check(device.Writes.SequenceEqual(expected), "Unexpected store writes: " + string.Join(",", device.Writes));
    static void Test(string name, Action action)
    {
        try { action(); passed++; Console.WriteLine("PASS " + name); }
        catch (Exception e) { failed++; Console.WriteLine("FAIL " + name + ": " + e.Message); }
    }
    public static int Main()
    {
        Test("read creates a separate Import0 CHI43 stage2 baseline without writes", () => {
            var device = new FakeDevice(Baseline()); var result = Engine.Read(device);
            Check(result.Success && result.Baseline.Schema == "qn90b-stage2-v1" && result.Baseline.PreventImport.Value == 0, result.Message); Writes(device);
            device.Apply(3); Check(result.Baseline.CurrentStore == 43 && result.Baseline.LocalSet.Value == 65, "Baseline/before snapshot was aliased");
        });
        Test("read at Singapore is valid but does not invent an original baseline", () => {
            var device = Singapore(); var result = Engine.Read(device);
            Check(result.Success && result.Baseline == null && result.State.CurrentStore == 3, result.Message); Writes(device);
        });
        Test("stage1 schema or Import13 baseline can never authorize stage2", () => {
            foreach (bool wrongSchema in new[] { true, false })
            {
                var baseline = Baseline();
                if (wrongSchema) baseline.Schema = "qn90b-stage1-v1";
                else { baseline.PreventImport.Value = 13; baseline.PreventImport.Display = "13"; }
                var device = new FakeDevice(Baseline()); var result = Engine.Execute(device, "apply", baseline);
                Check(!result.Success && !result.WriteAttempted, "Wrong original baseline passed"); Writes(device);
            }
        });
        Test("identity hashes metadata Import and store/global/name failures block every write", () => {
            var changes = new List<Action<State>> {
                s => s.EffectiveUid = 5001, s => s.BuildId = "different", s => s.DeviceToken = new string('c',64),
                s => s.DeviceTokenSource = "other", s => s.LocalSet.Uid = 195, s => s.LocalSet.Tpid = 402,
                s => s.LocalSet.Name = "Other", s => s.LocalSet.Display = "OTHER", s => s.LocalSet.Value = 99,
                s => s.PreventImport.Value = 13, s => s.PreventImport.Display = "13", s => s.PreventImport.Tpid = 140201,
                s => s.ConvertedCurrentStore = 0, s => s.SingaporeStore = 0, s => s.SingaporeName = "NONE",
                s => s.ChinaStore = 65, s => s.VisibleLocalSets.RemoveAll(x => x.Store == 3),
                s => s.VisibleLocalSets.First(x => x.Store == 4).Name = "AD_SIN2", s => s.ReadErrors.Add("required getter failure")
            };
            foreach (string path in Policy.ExpectedHashes.Keys) { string key = path; changes.Add(s => s.EvidenceHashes[key] = new string('0',64)); }
            foreach (var change in changes)
                foreach (string action in new[] { "apply", "restore" })
                {
                    var device = action == "restore" ? Singapore() : new FakeDevice(Baseline()); change(device.Current);
                    var result = Engine.Execute(device, action, Baseline());
                    Check(!result.Success && !result.WriteAttempted && !result.RollbackAttempted, "Unverified state reached writer"); Writes(device);
                }
        });
        Test("apply writes raw store3 rather than enum25 and keeps Import0", () => {
            var baseline = Baseline(); var device = new FakeDevice(baseline); var result = Engine.Execute(device, "apply", baseline);
            Check(result.Success && result.Changed && result.Before.CurrentStore == 43 && result.State.CurrentStore == 3 && result.State.GlobalEnum == 25 && result.State.PreventImport.Value == 0, result.Message);
            Check(baseline.CurrentStore == 43 && baseline.PreventImport.Value == 0, "Saved baseline changed"); Writes(device, 3);
        });
        Test("apply at Singapore and restore at China are idempotent", () => {
            var sg = Singapore(); var result = Engine.Execute(sg, "apply", Baseline()); Check(result.Success && !result.WriteAttempted && !result.Changed, result.Message); Writes(sg);
            var chi = new FakeDevice(Baseline()); result = Engine.Execute(chi, "restore", Baseline()); Check(result.Success && !result.WriteAttempted && !result.Changed, result.Message); Writes(chi);
        });
        Test("restore writes raw store43 rather than enum65 and leaves Import0", () => {
            var device = Singapore(); var result = Engine.Execute(device, "restore", Baseline());
            Check(result.Success && result.Changed && result.State.CurrentStore == 43 && result.State.GlobalEnum == 65 && result.State.PreventImport.Value == 0, result.Message); Writes(device, 43);
        });
        Test("unrelated LocalSet state is never overwritten", () => {
            var device = new FakeDevice(Baseline()); device.Current.CurrentStore = device.Current.ConvertedCurrentStore = 1;
            device.Current.GlobalEnum = device.Current.LocalSet.Value = 1; device.Current.CurrentName = device.Current.LocalSet.Display = "US";
            var result = Engine.Execute(device, "restore", Baseline()); Check(!result.Success && !result.WriteAttempted, "Unrelated state overwritten"); Writes(device);
        });
        Test("setter failure after mutation recovers original store43", () => {
            var device = new FakeDevice(Baseline()); device.OnSet = (d, store) => { if (d.Writes.Count != 1) return null; d.Apply(store); return 0; };
            var result = Engine.Execute(device, "apply", Baseline()); Check(!result.Success && result.RollbackSucceeded && !result.Changed && result.State.CurrentStore == 43 && result.State.PreventImport.Value == 0, result.Message); Writes(device, 3, 43);
        });
        Test("setter exception after mutation also recovers43", () => {
            var device = new FakeDevice(Baseline()); device.OnSet = (d, store) => { if (d.Writes.Count != 1) return null; d.Apply(store); throw new Exception("post-write exception"); };
            var result = Engine.Execute(device, "apply", Baseline()); Check(!result.Success && result.RollbackSucceeded && result.State.CurrentStore == 43, result.Message); Writes(device, 3, 43);
        });
        Test("successful setter without target readback is not accepted", () => {
            var device = new FakeDevice(Baseline()); device.OnSet = (d, store) => d.Writes.Count == 1 ? 1 : (int?)null;
            var result = Engine.Execute(device, "apply", Baseline()); Check(!result.Success && result.RollbackSucceeded && result.State.CurrentStore == 43, result.Message); Writes(device, 3, 43);
        });
        Test("failed restore retries43 and never writes3 as a rollback", () => {
            var device = Singapore(); device.OnSet = (d, store) => { if (d.Writes.Count != 1) return null; d.Apply(store); return 0; };
            var result = Engine.Execute(device, "restore", Baseline()); Check(!result.Success && result.RollbackSucceeded && result.Changed && result.State.CurrentStore == 43 && result.State.PreventImport.Value == 0, result.Message); Writes(device, 43, 43);
        });
        Test("unexpected Import change is reported but never corrected by stage2", () => {
            var device = new FakeDevice(Baseline()); device.OnSet = (d, store) => { if (d.Writes.Count != 1) return null; d.Apply(store); d.Current.PreventImport.Value = 13; d.Current.PreventImport.Display = "13"; return 1; };
            var result = Engine.Execute(device, "apply", Baseline()); Check(!result.Success && !result.RollbackSucceeded && result.Changed && result.State.CurrentStore == 43 && result.State.PreventImport.Value == 13, result.Message); Writes(device, 3, 43);
        });
        Test("failed recovery reports fresh actualSingapore rather than cachedChina", () => {
            var device = new FakeDevice(Baseline()); device.OnRead = (s, count) => { if (count == 2) s.ReadErrors.Add("post-write read failed"); };
            device.OnSet = (d, store) => d.Writes.Count == 2 ? 0 : (int?)null;
            var result = Engine.Execute(device, "apply", Baseline()); Check(!result.Success && !result.RollbackSucceeded && result.Changed && result.State.CurrentStore == 3 && result.State.GlobalEnum == 25 && device.Reads == 3, result.Message); Writes(device, 3, 43);
        });
        Test("unreadable latest state after recovery is null", () => {
            var device = new FakeDevice(Baseline()); device.OnRead = (s, count) => { if (count >= 2) throw new Exception("read unavailable"); };
            var result = Engine.Execute(device, "apply", Baseline()); Check(!result.Success && !result.RollbackSucceeded && result.State == null && result.Changed, result.Message); Writes(device, 3, 43);
        });
        Test("observed LocalSet metadata middle integer3 is not treated as currentstore43", () => {
            object[] payload = VariantReader.SuccessfulPayload("((401, 0, 3, 1000000069, 6, byte 0x01, 'CHI_DTV', 'Local Set'), (1,))");
            Check((int)payload[0] == 401 && (int)payload[2] == 3 && (string)payload[6] == "CHI_DTV" && (string)payload[7] == "Local Set", "Observed tuple did not parse");
            Check(Engine.CheckState(Baseline()) == "", "Current store must come from the list getter, independent of metadata middle fields");
        });
        Console.WriteLine("RESULT passed=" + passed + " failed=" + failed + "; NativeDevice not linked; no TV/native call or Import setter executed.");
        return failed == 0 ? 0 : 1;
    }
}
