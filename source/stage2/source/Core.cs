// Stage 2 writes only Local Set UID194 raw store3 or43. Import is read-only.
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Text.RegularExpressions;

namespace QN90BStage2
{
    public sealed class Item
    {
        public int Uid { get; set; }
        public int Tpid { get; set; }
        public string Name { get; set; } = "";
        public string Display { get; set; } = "";
        public int Value { get; set; }
        public int? Minimum { get; set; }
        public int? Maximum { get; set; }
    }
    public sealed class LocalOption
    {
        public int Store { get; set; }
        public string Name { get; set; } = "";
    }
    public sealed class State
    {
        public string Schema { get; set; } = Policy.Schema;
        public string CapturedUtc { get; set; } = DateTime.UtcNow.ToString("o");
        public uint EffectiveUid { get; set; }
        public string BuildId { get; set; } = "";
        public string DeviceToken { get; set; } = "";
        public string DeviceTokenSource { get; set; } = "/etc/machine-id";
        public Dictionary<string, string> EvidenceHashes { get; set; } = new Dictionary<string, string>();
        public Item PreventImport { get; set; }
        public Item LocalSet { get; set; }
        public int MaxStore { get; set; } = -1;
        public int CurrentStore { get; set; } = -1;
        public string CurrentName { get; set; } = "";
        public int GlobalEnum { get; set; } = -1;
        public int ConvertedCurrentStore { get; set; } = -1;
        public int SingaporeStore { get; set; } = -1;
        public string SingaporeName { get; set; } = "";
        public int ChinaStore { get; set; } = -1;
        public string ChinaName { get; set; } = "";
        public List<LocalOption> VisibleLocalSets { get; set; } = new List<LocalOption>();
        public List<string> ReadErrors { get; set; } = new List<string>();
        public bool ReadyToWrite { get; set; }
        public string WriteGateReason { get; set; } = "";
    }
    public sealed class Outcome
    {
        public string Phase { get; set; } = "";
        public bool Success { get; set; }
        public bool Changed { get; set; }
        public bool WriteAttempted { get; set; }
        public string Message { get; set; } = "";
        public State Before { get; set; }
        public State State { get; set; }
        public State Baseline { get; set; }
        public bool RollbackAttempted { get; set; }
        public bool RollbackSucceeded { get; set; }
        public List<string> Events { get; set; } = new List<string>();
    }
    public interface IDevice
    {
        State Read();
        int SetLocalSetStore(int store);
    }
    public static class Policy
    {
        public const string Schema = "qn90b-stage2-v1";
        public const string ExpectedBuild = "T-PTMUABC-REL-202509042046";
        public const string FactoryLibrary = "/usr/lib/libfactory-interface-DVBISDB.so";
        public static readonly IReadOnlyDictionary<string, string> ExpectedHashes =
            new ReadOnlyDictionary<string, string>(new Dictionary<string, string> {
                { FactoryLibrary, "5f418d8a41fd6f307c76d013e36a1e6637496a7583c12f5bfff7baae8ac95670" },
                { "/usr/lib/libfactory-data-config.so.00.00.0057", "d469fa60c691729bba332ede19ab7d35b593944912fe8afbb44149f8c5902c35" },
                { "/usr/bin/TIFSDaemon", "550d7260e6f2f6e0d41d83d95f51a15cfd90b4f839609ffcad67b5e1d29320db" },
                { "/factory_peq/factory-data/FactoryIndexFile_Part1.dat", "8c15d893bafc042683ed3c64e95c97d669f07188367a7b240bc912091c5d8fb5" }
            });
    }
    public static class Engine
    {
        static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
        static bool IsChina(State state) => state != null && state.CurrentStore == 43 && state.CurrentName == "CHI_DTV" && state.GlobalEnum == 65;
        static bool IsSingapore(State state) => state != null && state.CurrentStore == 3 && state.CurrentName == "AD_SIN2" && state.GlobalEnum == 25;
        static bool SameLocal(State a, State b) => a != null && b != null && a.CurrentStore == b.CurrentStore && a.CurrentName == b.CurrentName && a.GlobalEnum == b.GlobalEnum;
        public static string CheckState(State state)
        {
            if (state == null || state.Schema != Policy.Schema) return "Missing state or unsupported Stage2 schema";
            if (state.ReadErrors == null || state.ReadErrors.Count != 0) return "One or more required reads failed";
            if (state.EffectiveUid != 0) return "Effective UID is not 0";
            if (state.BuildId != Policy.ExpectedBuild) return "BUILD_ID does not match the collected firmware";
            if (state.EvidenceHashes == null || state.EvidenceHashes.Count != Policy.ExpectedHashes.Count) return "Missing firmware fingerprints";
            foreach (var expected in Policy.ExpectedHashes)
            {
                string actual;
                if (!state.EvidenceHashes.TryGetValue(expected.Key, out actual) || actual != expected.Value) return "Firmware fingerprint mismatch: " + expected.Key;
            }
            if (state.DeviceTokenSource != "/etc/machine-id" || !Regex.IsMatch(state.DeviceToken ?? "", "^[a-f0-9]{64}$")) return "Missing machine identity binding";
            var import = state.PreventImport;
            if (import == null || import.Uid != 761 || import.Tpid != 140202 || import.Name != "Preventing Import" || import.Minimum != 0 || import.Maximum != 13)
                return "Preventing Import metadata or range mismatch";
            int display;
            if (import.Value != 0 || !int.TryParse(import.Display, NumberStyles.Integer, CultureInfo.InvariantCulture, out display) || display != 0)
                return "Stage2 requires Preventing Import0; this helper never changes it";
            var local = state.LocalSet;
            if (local == null || local.Uid != 194 || local.Tpid != 401 || local.Name != "Local Set") return "UID194 / TPID401 / Local Set mapping was not confirmed";
            if (state.MaxStore != 54 || (!IsChina(state) && !IsSingapore(state))) return "Local Set is outside the authorized CHI43/65 and AD_SIN2/3/25 states";
            if (local.Value != state.GlobalEnum || local.Display != state.CurrentName || state.ConvertedCurrentStore != state.CurrentStore)
                return "Local Set native/global/store/name cross-check failed";
            if (state.SingaporeStore != 3 || state.SingaporeName != "AD_SIN2" || state.ChinaStore != 43 || state.ChinaName != "CHI_DTV")
                return "Global25/store3 or global65/store43 name mapping was not confirmed";
            if (state.VisibleLocalSets == null || state.VisibleLocalSets.Count == 0) return "No visible Local Set entries";
            var stores = new HashSet<int>();
            foreach (var entry in state.VisibleLocalSets)
                if (entry == null || entry.Store < 0 || entry.Store > 54 || string.IsNullOrWhiteSpace(entry.Name) || !stores.Add(entry.Store)) return "Invalid or duplicate visible Local Set entry";
            var singapore = state.VisibleLocalSets.Where(x => x.Name == "AD_SIN2").ToList();
            if (singapore.Count != 1 || singapore[0].Store != 3) return "AD_SIN2 is not uniquely visible at store3";
            if (!state.VisibleLocalSets.Any(x => x.Store == 43 && x.Name == "CHI_DTV")) return "Original CHI_DTV is not visible at store43";
            if (!state.VisibleLocalSets.Any(x => x.Store == state.CurrentStore && x.Name == state.CurrentName)) return "Current Local Set is absent from the visible list";
            return "";
        }
        static void RequireValid(State state, string label)
        {
            string reason = CheckState(state); Require(reason.Length == 0, label + ": " + reason);
        }
        static void Validate(State baseline, State current)
        {
            RequireValid(baseline, "Stage2 baseline rejected");
            Require(IsChina(baseline), "Stage2 baseline must record original CHI_DTV/store43/global65 with Import0");
            RequireValid(current, "Current state rejected");
            Require(current.DeviceToken == baseline.DeviceToken, "Machine identity changed since the Stage2 baseline");
        }
        public static Outcome Read(IDevice device)
        {
            var result = new Outcome { Phase = "read" };
            try
            {
                State state = device.Read(); result.State = state;
                string reason = CheckState(state);
                if (state != null) { state.WriteGateReason = reason; state.ReadyToWrite = reason.Length == 0; }
                result.Success = reason.Length == 0;
                if (result.Success && IsChina(state)) result.Baseline = state;
                result.Message = result.Success
                    ? (IsChina(state) ? "Read-only Stage2 checks passed. Original CHI43/65 with Import0 baseline is available." : "Read-only Stage2 checks passed. Local Set is already AD_SIN2/store3/global25; an existing Stage2 baseline is required for apply or restore.")
                    : "Read-only Stage2 checks failed: " + reason;
            }
            catch (Exception e) { result.Message = "Read failed: " + e.Message; }
            return result;
        }
        public static Outcome Execute(IDevice device, string action, State baseline)
        {
            var result = new Outcome { Phase = action, Baseline = baseline };
            State before = null;
            try
            {
                Require(action == "apply" || action == "restore", "Use apply or restore with an original Stage2 baseline");
                before = device.Read(); result.Before = before; result.State = before;
                Validate(baseline, before);
                if (action == "apply" && IsSingapore(before))
                {
                    result.Success = true; result.Message = "Local Set already reads AD_SIN2/store3/global25 and Import0. Nothing was written."; return result;
                }
                if (action == "restore" && IsChina(before))
                {
                    result.Success = true; result.Message = "Local Set already reads CHI_DTV/store43/global65 and Import0. Nothing was written."; return result;
                }
                int target = action == "apply" ? 3 : 43;
                result.WriteAttempted = true;
                result.Events.Add("write-attempt UID194 raw store " + before.CurrentStore + " -> " + target + "; Import is read-only");
                int rc = device.SetLocalSetStore(target);
                result.Events.Add("Local Set setter rc=" + rc);
                Require(rc == 1, "Local Set setter did not return success1");
                State after = device.Read(); result.State = after;
                Validate(baseline, after);
                Require(after.PreventImport.Value == before.PreventImport.Value && (action == "apply" ? IsSingapore(after) : IsChina(after)), "Local Set target or unchanged Import0 readback failed");
                result.Success = true; result.Changed = true;
                result.Message = action == "apply"
                    ? "Local Set reads AD_SIN2/store3/global25; Preventing Import remains0. Only the Local Set storage parameter was changed; app availability and reboot persistence are not verified."
                    : "Local Set reads CHI_DTV/store43/global65 again; Preventing Import remains0. Stage1 Restore is a separate action if the original Import13 restriction is wanted.";
            }
            catch (Exception e)
            {
                result.Success = false; result.Message = e.Message;
                if (result.WriteAttempted)
                {
                    result.RollbackAttempted = true;
                    try
                    {
                        result.Events.Add("recovery-attempt UID194 raw store -> 43; Import is read-only");
                        int rc = device.SetLocalSetStore(43);
                        result.Events.Add("Local Set recovery setter rc=" + rc);
                        Require(rc == 1, "Local Set recovery setter did not return success1");
                        State recovered = device.Read(); result.State = recovered;
                        Validate(baseline, recovered);
                        Require(IsChina(recovered) && recovered.PreventImport.Value == 0, "Recovery did not confirm CHI43/global65 and unchanged Import0");
                        result.RollbackSucceeded = true;
                        result.Message += " Recovery to CHI_DTV/store43/global65 was verified; Import remains0.";
                    }
                    catch (Exception recoveryError)
                    {
                        result.Message += " RECOVERY TO CHI43 NOT VERIFIED: " + recoveryError.Message;
                        try { result.State = device.Read(); }
                        catch (Exception readError) { result.State = null; result.Message += " Latest state could not be read: " + readError.Message; }
                    }
                    result.Changed = result.State == null || CheckState(result.State).Length != 0 || before == null || !SameLocal(before, result.State) ||
                        result.State.PreventImport.Value != before.PreventImport.Value;
                }
            }
            return result;
        }
    }
}
