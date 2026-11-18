// Stage 1 is limited to the observed Preventing Import 13/0 values.
// The device contract has no Local Set setter and no general UID setter.
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Text.RegularExpressions;

namespace QN90BStage1
{
    public sealed class Item
    {
        public int Uid { get; set; }
        public int Tpid { get; set; }
        public string Name { get; set; } = "";
        public string Display { get; set; } = "";
        public int Value { get; set; }
        public int Minimum { get; set; } = int.MinValue;
        public int Maximum { get; set; } = int.MinValue;
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
        public int MaxStore { get; set; } = -1;
        public int CurrentStore { get; set; } = -1;
        public string CurrentName { get; set; } = "";
        public int GlobalEnum { get; set; } = -1;
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
        int SetPreventImport(int value);
    }
    public static class Policy
    {
        public const string Schema = "qn90b-stage1-v1";
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
        static void Require(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException(message);
        }
        public static string CheckState(State state)
        {
            if (state == null || state.Schema != Policy.Schema) return "Missing state or unsupported schema";
            if (state.ReadErrors == null || state.ReadErrors.Count != 0) return "One or more required reads failed";
            if (state.EffectiveUid != 0) return "Effective UID is not 0";
            if (state.BuildId != Policy.ExpectedBuild) return "BUILD_ID does not match the collected firmware";
            if (state.EvidenceHashes == null || state.EvidenceHashes.Count != Policy.ExpectedHashes.Count) return "Missing firmware fingerprints";
            foreach (var expected in Policy.ExpectedHashes)
            {
                string actual;
                if (!state.EvidenceHashes.TryGetValue(expected.Key, out actual) || actual != expected.Value)
                    return "Firmware fingerprint mismatch: " + expected.Key;
            }
            if (state.DeviceTokenSource != "/etc/machine-id" || !Regex.IsMatch(state.DeviceToken ?? "", "^[a-f0-9]{64}$"))
                return "Missing machine identity binding";
            var item = state.PreventImport;
            if (item == null || item.Uid != 761 || item.Tpid != 140202 || item.Name != "Preventing Import")
                return "UID761 / TPID140202 / Preventing Import mapping was not confirmed";
            if (item.Minimum != 0 || item.Maximum != 13) return "UID761 range is not the verified 0..13 range";
            if (item.Value != 0 && item.Value != 13) return "Preventing Import is outside the authorized 0/13 states";
            int displayValue;
            if (!int.TryParse(item.Display, NumberStyles.Integer, CultureInfo.InvariantCulture, out displayValue) || displayValue != item.Value)
                return "Native value and D-Bus display disagree";
            if (state.MaxStore != 54 || state.CurrentStore != 43 || state.CurrentName != "CHI_DTV" || state.GlobalEnum != 65)
                return "Local Set is outside the observed 43 / CHI_DTV / enum65 state";
            if (state.VisibleLocalSets == null || state.VisibleLocalSets.Count == 0) return "No visible Local Set entries";
            var stores = new HashSet<int>();
            foreach (var entry in state.VisibleLocalSets)
            {
                if (entry == null || entry.Store < 0 || entry.Store > state.MaxStore || string.IsNullOrWhiteSpace(entry.Name) || !stores.Add(entry.Store))
                    return "Invalid or duplicate visible Local Set entry";
            }
            if (!state.VisibleLocalSets.Any(x => x.Store == state.CurrentStore && x.Name == state.CurrentName))
                return "Current Local Set is absent from the visible list";
            return "";
        }
        static void RequireValid(State state, string name)
        {
            string reason = CheckState(state);
            Require(reason.Length == 0, name + ": " + reason);
        }
        static void Validate(State baseline, State current)
        {
            RequireValid(baseline, "Baseline rejected");
            Require(baseline.PreventImport.Value == 13, "Baseline must record the original Import13 state");
            RequireValid(current, "Current state rejected");
            Require(current.DeviceToken == baseline.DeviceToken, "Machine identity changed since the baseline");
        }
        static bool SameLocal(State a, State b)
        {
            return a != null && b != null && a.CurrentStore == b.CurrentStore && a.CurrentName == b.CurrentName && a.GlobalEnum == b.GlobalEnum;
        }
        static bool Expanded(State baseline, State current)
        {
            return current.VisibleLocalSets.Count > baseline.VisibleLocalSets.Count &&
                baseline.VisibleLocalSets.All(old => current.VisibleLocalSets.Any(now => now.Store == old.Store && now.Name == old.Name));
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
                if (result.Success && state.PreventImport.Value == 13) result.Baseline = state;
                result.Message = result.Success
                    ? (state.PreventImport.Value == 13 ? "Read-only checks passed. Original Import13 baseline is available." : "Read-only checks passed. Import is already 0; an existing Import13 baseline is required for apply or restore.")
                    : "Read-only checks failed: " + reason;
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
                Require(action == "apply" || action == "restore", "Use apply or restore with an original baseline");
                before = device.Read(); result.Before = before; result.State = before;
                Validate(baseline, before);
                if (action == "apply" && before.PreventImport.Value == 0)
                {
                    Require(Expanded(baseline, before), "Import is 0 but the visible list is not a verified expansion of the baseline");
                    result.Success = true;
                    result.Message = "Import is already 0, Local Set is unchanged, and the list is expanded. Nothing was written.";
                    return result;
                }
                if (action == "restore" && before.PreventImport.Value == 13)
                {
                    result.Success = true; result.Message = "Import is already 13 and Local Set matches the baseline. Nothing was written.";
                    return result;
                }
                int target = action == "apply" ? 0 : 13;
                // Journal the attempt BEFORE entering the native call: a failing return
                // or exception does not prove that no parameter value changed.
                result.WriteAttempted = true;
                result.Events.Add("write-attempt Preventing Import " + before.PreventImport.Value + " -> " + target);
                int rc = device.SetPreventImport(target);
                result.Events.Add("setter rc=" + rc);
                Require(rc == 1, "Preventing Import setter did not return success 1");
                State after = device.Read(); result.State = after;
                Validate(baseline, after);
                Require(after.PreventImport.Value == target && SameLocal(before, after), "Parameter or unchanged Local Set readback failed");
                if (action == "apply") Require(Expanded(before, after), "Visible Local Set list did not expand while preserving baseline entries");
                result.Success = true;
                result.Changed = true;
                result.Message = action == "apply"
                    ? "Preventing Import changed 13 -> 0; Local Set remains CHI_DTV/store43/enum65; the visible list expanded. Reboot persistence is not verified."
                    : "Preventing Import reads 13 again; Local Set remains CHI_DTV/store43/enum65. Reboot persistence is not verified.";
            }
            catch (Exception e)
            {
                result.Success = false; result.Message = e.Message;
                if (result.WriteAttempted)
                {
                    result.RollbackAttempted = true;
                    try
                    {
                        result.Events.Add("recovery-attempt Preventing Import -> 13");
                        int rc = device.SetPreventImport(13);
                        result.Events.Add("recovery setter rc=" + rc);
                        Require(rc == 1, "Recovery setter did not return success 1");
                        State recovered = device.Read(); result.State = recovered;
                        Validate(baseline, recovered);
                        Require(recovered.PreventImport.Value == 13 && SameLocal(before, recovered), "Recovery readback did not confirm Import13 with unchanged Local Set");
                        result.RollbackSucceeded = true;
                        result.Message += " Recovery to Import13 was verified; Local Set was unchanged.";
                    }
                    catch (Exception recoveryError)
                    {
                        result.Message += " RECOVERY TO 13 NOT VERIFIED: " + recoveryError.Message;
                        try { result.State = device.Read(); }
                        catch (Exception readError) { result.State = null; result.Message += " Latest state could not be read: " + readError.Message; }
                    }
                    // Recovery during restore also targets 13, NEVER the pre-operation 0.
                    result.Changed = result.State == null || CheckState(result.State).Length != 0 || before == null ||
                        result.State.PreventImport.Value != before.PreventImport.Value || !SameLocal(before, result.State);
                }
            }
            return result;
        }
    }
}
