using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace QN90BStage2
{
    public sealed class FactoryReply
    {
        public object[] Payload { get; set; }
        public int Code { get; set; }
    }
    // Restricted GVariant tuple/string/integer parser. No eval or shell parsing.
    public sealed class VariantReader
    {
        readonly string text;
        int pos;
        VariantReader(string value) { text = value ?? ""; }
        void Space() { while (pos < text.Length && char.IsWhiteSpace(text[pos])) pos++; }
        char Peek { get { Space(); return pos < text.Length ? text[pos] : '\0'; } }
        object Value()
        {
            char c = Peek;
            if (c == '(')
            {
                pos++;
                var values = new List<object>();
                while (Peek != ')')
                {
                    values.Add(Value());
                    if (Peek == ',') pos++;
                    else if (Peek != ')') throw new FormatException("Unexpected GVariant separator");
                    if (pos >= text.Length) throw new FormatException("Unclosed GVariant tuple");
                }
                pos++;
                return values.ToArray();
            }
            if (c == '\'' || c == '"')
            {
                pos++;
                var value = new StringBuilder();
                bool closed = false;
                while (pos < text.Length)
                {
                    char x = text[pos++];
                    if (x == c) { closed = true; break; }
                    if (x == '\\')
                    {
                        if (pos == text.Length) throw new FormatException("Truncated string escape");
                        x = text[pos++];
                        if (x == 'n') x = '\n';
                        else if (x == 'r') x = '\r';
                        else if (x == 't') x = '\t';
                        else if (x != '\\' && x != '\'' && x != '"') throw new FormatException("Unsupported string escape");
                    }
                    value.Append(x);
                }
                if (!closed) throw new FormatException("Unclosed GVariant string");
                return value.ToString();
            }
            if (char.IsLetter(c))
            {
                int begin = pos;
                while (pos < text.Length && char.IsLetterOrDigit(text[pos])) pos++;
                string annotation = text.Substring(begin, pos - begin);
                if (annotation != "int32" && annotation != "uint32" && annotation != "byte")
                    throw new FormatException("Unsupported GVariant annotation");
                return Value();
            }
            int start = pos;
            if (c == '-') pos++;
            while (pos < text.Length && char.IsLetterOrDigit(text[pos])) pos++;
            if (start == pos) throw new FormatException("Expected GVariant value");
            string number = text.Substring(start, pos - start);
            return number.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
                ? int.Parse(number.Substring(2), NumberStyles.HexNumber, CultureInfo.InvariantCulture)
                : int.Parse(number, CultureInfo.InvariantCulture);
        }
        public static FactoryReply Decode(string text)
        {
            var reader = new VariantReader(text);
            var outer = reader.Value() as object[];
            if (reader.Peek != '\0' || outer == null || outer.Length != 2 || !(outer[0] is object[]) || !(outer[1] is object[]))
                throw new FormatException("Unexpected factory reply shape");
            var result = (object[])outer[1];
            if (result.Length != 1 || !(result[0] is int)) throw new FormatException("Invalid factory return code");
            return new FactoryReply { Payload = (object[])outer[0], Code = (int)result[0] };
        }
        public static object[] SuccessfulPayload(string text)
        {
            FactoryReply reply = Decode(text);
            if (reply.Code != 1) throw new InvalidOperationException("Factory getter did not return success 1");
            return reply.Payload;
        }
        public static string LocalSetName(string text, bool allowHidden)
        {
            FactoryReply reply = Decode(text);
            if (reply.Payload.Length != 1 || !(reply.Payload[0] is string)) throw new FormatException("Invalid Local Set name reply");
            string name = (string)reply.Payload[0];
            if (allowHidden && reply.Code == 0 && name.Length == 0) return null;
            if (reply.Code != 1 || string.IsNullOrWhiteSpace(name)) throw new InvalidOperationException("Local Set getter did not return a valid visible name");
            return name;
        }
    }
}
