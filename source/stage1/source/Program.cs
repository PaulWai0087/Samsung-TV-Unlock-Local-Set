using System;
using System.IO;
using System.Text.Json;

namespace QN90BStage1
{
    public static class Program
    {
        public static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true };
        public static int Main(string[] args)
        {
            string action = args.Length == 0 ? "read" : args[0];
            Outcome result;
            try
            {
                var device = new NativeDevice();
                if (action == "read" && args.Length <= 1) result = Engine.Read(device);
                else
                {
                    if ((action != "apply" && action != "restore") || args.Length != 3 || args[1] != "--baseline")
                        throw new ArgumentException("Use read, apply --baseline FILE, or restore --baseline FILE");
                    State baseline = JsonSerializer.Deserialize<State>(File.ReadAllText(args[2]), JsonOptions);
                    result = Engine.Execute(device, action, baseline);
                }
            }
            catch (Exception e) { result = new Outcome { Phase = action, Success = false, Message = e.GetType().Name + ": " + e.Message }; }
            Console.WriteLine();
            Console.WriteLine("QN90B_STAGE1_JSON=" + JsonSerializer.Serialize(result, JsonOptions));
            return result.Success ? 0 : 2;
        }
    }
}
