using System;
using System.Collections.Generic;
using System.Text;

internal static class HookInputTests
{
    private static int Main()
    {
        return CheckUtf8Object()
            && CheckBomObject()
            && CheckWhitespace()
            && CheckInvalidInputs()
            && CheckNestedTurnIds()
            ? 0
            : 1;
    }

    private static bool CheckUtf8Object()
    {
        IDictionary<string, object> data;
        return Program.TryDecodeInput(Encoding.UTF8.GetBytes("{\"prompt\":\"完成中文摘要\",\"turn_id\":\"turn-root\"}"), out data)
            && Program.ExtractTurnId(data) == "turn-root";
    }

    private static bool CheckBomObject()
    {
        var body = Encoding.UTF8.GetBytes("{\"turnId\":\"turn-bom\"}");
        var bytes = new byte[body.Length + 3];
        bytes[0] = 0xef;
        bytes[1] = 0xbb;
        bytes[2] = 0xbf;
        Buffer.BlockCopy(body, 0, bytes, 3, body.Length);
        IDictionary<string, object> data;
        return Program.TryDecodeInput(bytes, out data) && Program.ExtractTurnId(data) == "turn-bom";
    }

    private static bool CheckWhitespace()
    {
        IDictionary<string, object> data;
        return Program.TryDecodeInput(Encoding.UTF8.GetBytes(" \r\n\t"), out data) && data.Count == 0;
    }

    private static bool CheckInvalidInputs()
    {
        IDictionary<string, object> data;
        return !Program.TryDecodeInput(new byte[] { 0xff }, out data)
            && !Program.TryDecodeInput(Encoding.UTF8.GetBytes("{"), out data)
            && !Program.TryDecodeInput(Encoding.UTF8.GetBytes("[]"), out data)
            && !Program.TryDecodeInput(Encoding.UTF8.GetBytes("null"), out data)
            && !Program.TryDecodeInput(new byte[(64 * 1024) + 1], out data);
    }

    private static bool CheckNestedTurnIds()
    {
        IDictionary<string, object> data;
        return Program.TryDecodeInput(Encoding.UTF8.GetBytes("{\"message\":{\"turnId\":\"turn-message\"}}"), out data)
            && Program.ExtractTurnId(data) == "turn-message"
            && Program.TryDecodeInput(Encoding.UTF8.GetBytes("{\"tool_input\":{\"turn_id\":\"turn-tool\"}}"), out data)
            && Program.ExtractTurnId(data) == "turn-tool";
    }
}
