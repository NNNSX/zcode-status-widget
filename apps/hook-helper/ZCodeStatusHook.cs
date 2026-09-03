using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

internal static class Program
{
    private const int SqliteOk = 0;
    private const int SqliteRow = 100;
    private const int SqliteOpenReadOnly = 1;
    private static readonly IntPtr SqliteTransient = new IntPtr(-1);
    private const int PromptPreviewLength = 60;
    private const int TaskPreviewLength = 80;
    private const int SessionDbMaxDepth = 16;
    private const int MaxInputBytes = 64 * 1024;
    private static readonly UTF8Encoding StrictUtf8 = new UTF8Encoding(false, true);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_open_v2(byte[] filename, out IntPtr database, int flags, IntPtr vfs);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close(IntPtr database);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_prepare_v2(IntPtr database, byte[] sql, int length, out IntPtr statement, IntPtr tail);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_bind_text(IntPtr statement, int index, byte[] value, int length, IntPtr destructor);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_step(IntPtr statement);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_column_text(IntPtr statement, int column);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_finalize(IntPtr statement);

    private static void Main(string[] args)
    {
        try
        {
            var eventToken = Expand(args, 0).ToLowerInvariant();
            var sessionId = Expand(args, 1);
            var projectDirectory = Expand(args, 2);
            var sessionDbPath = Expand(args, 3);
            if (String.IsNullOrWhiteSpace(projectDirectory))
            {
                projectDirectory = Environment.GetEnvironmentVariable("ZCODE_PROJECT_DIR")
                    ?? Environment.GetEnvironmentVariable("CLAUDE_PROJECT_DIR")
                    ?? String.Empty;
            }

            IDictionary<string, object> data;
            if (!TryReadInput(out data))
            {
                return;
            }
            Send(BuildPayload(eventToken, sessionId, projectDirectory, sessionDbPath, data));
        }
        catch
        {
            // Hook failures must never block ZCode or emit stdout.
        }
    }

    private static string Expand(string[] args, int index)
    {
        if (args == null || index >= args.Length || String.IsNullOrWhiteSpace(args[index]))
        {
            return String.Empty;
        }
        return Regex.Replace(args[index], @"\$\{[^}]*\}", String.Empty).Trim();
    }

    private static bool TryReadInput(out IDictionary<string, object> data)
    {
        data = new Dictionary<string, object>();
        if (!Console.IsInputRedirected)
        {
            return true;
        }
        try
        {
            byte[] raw;
            using (var input = Console.OpenStandardInput())
            {
                raw = ReadInputBytes(input);
            }
            return TryDecodeInput(raw, out data);
        }
        catch
        {
            return false;
        }
    }

    internal static bool TryDecodeInput(byte[] raw, out IDictionary<string, object> data)
    {
        data = new Dictionary<string, object>();
        if (raw == null || raw.Length > MaxInputBytes)
        {
            return false;
        }
        try
        {
            var offset = HasUtf8Bom(raw) ? 3 : 0;
            var text = StrictUtf8.GetString(raw, offset, raw.Length - offset);
            if (String.IsNullOrWhiteSpace(text))
            {
                return true;
            }
            var parsed = new JavaScriptSerializer().DeserializeObject(text) as IDictionary<string, object>;
            if (parsed == null)
            {
                return false;
            }
            data = parsed;
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static byte[] ReadInputBytes(Stream input)
    {
        using (var output = new MemoryStream())
        {
            var buffer = new byte[4096];
            while (true)
            {
                var count = input.Read(buffer, 0, buffer.Length);
                if (count == 0)
                {
                    break;
                }
                if (output.Length + count > MaxInputBytes)
                {
                    return null;
                }
                output.Write(buffer, 0, count);
            }
            return output.ToArray();
        }
    }

    private static bool HasUtf8Bom(byte[] bytes)
    {
        return bytes.Length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf;
    }

    private static IDictionary<string, object> BuildPayload(
        string eventToken,
        string sessionId,
        string projectDirectory,
        string sessionDbPath,
        IDictionary<string, object> data)
    {
        var workspaceDirectory = RootWorkspaceDirectory(sessionId, sessionDbPath);
        var displayDirectory = !String.IsNullOrWhiteSpace(workspaceDirectory) ? workspaceDirectory : projectDirectory;
        var project = WorkspaceName(displayDirectory);
        var todos = ExtractTodos(data);
        var currentTask = String.Empty;
        foreach (var todo in todos)
        {
            object status;
            if (todo.TryGetValue("status", out status) && String.Equals(StringValue(status), "in_progress", StringComparison.Ordinal))
            {
                object content;
                if (todo.TryGetValue("content", out content))
                {
                    currentTask = StringValue(content);
                }
                break;
            }
        }

        return new Dictionary<string, object>
        {
            { "event", eventToken },
            { "session_id", sessionId },
            { "project", project },
            { "project_dir", projectDirectory },
            { "workspace_dir", workspaceDirectory },
            { "workspace_source", !String.IsNullOrWhiteSpace(workspaceDirectory) ? "session_root" : "event_dir" },
            { "prompt_preview", ExtractPrompt(data) },
            { "last_tool", ExtractToolName(data) },
            { "error_preview", ExtractError(data) },
            { "todos", todos },
            { "current_task", currentTask },
            { "turn_id", ExtractTurnId(data) },
            { "ts", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0 },
        };
    }

    private static string RootWorkspaceDirectory(string sessionId, string sessionDbPath)
    {
        if (String.IsNullOrWhiteSpace(sessionId) || String.IsNullOrWhiteSpace(sessionDbPath) || !File.Exists(sessionDbPath))
        {
            return String.Empty;
        }

        IntPtr database = IntPtr.Zero;
        try
        {
            if (sqlite3_open_v2(Utf8(sessionDbPath), out database, SqliteOpenReadOnly, IntPtr.Zero) != SqliteOk)
            {
                return String.Empty;
            }

            var current = sessionId;
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var rootDirectory = String.Empty;
            for (var depth = 0; depth < SessionDbMaxDepth; depth += 1)
            {
                if (String.IsNullOrWhiteSpace(current) || !seen.Add(current))
                {
                    return String.Empty;
                }

                string directory;
                string parentId;
                if (!ReadSession(database, current, out directory, out parentId))
                {
                    return String.Empty;
                }
                if (!String.IsNullOrWhiteSpace(directory))
                {
                    rootDirectory = directory.Trim();
                }
                current = parentId == null ? String.Empty : parentId.Trim();
                if (String.IsNullOrWhiteSpace(current))
                {
                    return rootDirectory;
                }
            }
        }
        catch
        {
            return String.Empty;
        }
        finally
        {
            if (database != IntPtr.Zero)
            {
                sqlite3_close(database);
            }
        }
        return String.Empty;
    }

    private static bool ReadSession(IntPtr database, string sessionId, out string directory, out string parentId)
    {
        directory = String.Empty;
        parentId = String.Empty;
        IntPtr statement = IntPtr.Zero;
        try
        {
            var sql = Utf8("SELECT directory, parent_id FROM session WHERE id = ?");
            if (sqlite3_prepare_v2(database, sql, -1, out statement, IntPtr.Zero) != SqliteOk)
            {
                return false;
            }
            var id = Utf8(sessionId);
            if (sqlite3_bind_text(statement, 1, id, id.Length - 1, SqliteTransient) != SqliteOk)
            {
                return false;
            }
            if (sqlite3_step(statement) != SqliteRow)
            {
                return false;
            }
            directory = Utf8String(sqlite3_column_text(statement, 0));
            parentId = Utf8String(sqlite3_column_text(statement, 1));
            return true;
        }
        finally
        {
            if (statement != IntPtr.Zero)
            {
                sqlite3_finalize(statement);
            }
        }
    }

    private static List<Dictionary<string, object>> ExtractTodos(IDictionary<string, object> data)
    {
        var holders = new List<IDictionary<string, object>> { data };
        IDictionary<string, object> toolInput;
        if (TryDictionary(data, "tool_input", out toolInput))
        {
            holders.Insert(0, toolInput);
        }
        IDictionary<string, object> message;
        if (TryDictionary(data, "message", out message))
        {
            holders.Add(message);
        }

        foreach (var holder in holders)
        {
            object rawTodos;
            var todoList = holder.TryGetValue("todos", out rawTodos) ? rawTodos as IEnumerable : null;
            if (todoList == null || rawTodos is string)
            {
                continue;
            }
            var result = new List<Dictionary<string, object>>();
            foreach (var rawTodo in todoList)
            {
                var todo = rawTodo as IDictionary<string, object>;
                if (todo == null)
                {
                    continue;
                }
                result.Add(new Dictionary<string, object>
                {
                    { "content", Clip(FirstString(todo, "content", "activeForm", "subject"), TaskPreviewLength) },
                    { "status", FirstString(todo, "status") ?? "pending" },
                });
            }
            return result;
        }
        return new List<Dictionary<string, object>>();
    }

    private static string ExtractPrompt(IDictionary<string, object> data)
    {
        return Clip(FirstString(data, "prompt", "user_prompt", "message"), PromptPreviewLength);
    }

    private static string ExtractToolName(IDictionary<string, object> data)
    {
        return Clip(FirstString(data, "tool_name", "toolName"), 40);
    }

    internal static string ExtractTurnId(IDictionary<string, object> data)
    {
        var value = FirstString(data, "turn_id", "turnId");
        if (!String.IsNullOrWhiteSpace(value))
        {
            return Clip(value, 128);
        }
        IDictionary<string, object> toolInput;
        if (TryDictionary(data, "tool_input", out toolInput))
        {
            value = FirstString(toolInput, "turn_id", "turnId");
            if (!String.IsNullOrWhiteSpace(value))
            {
                return Clip(value, 128);
            }
        }
        IDictionary<string, object> message;
        if (TryDictionary(data, "message", out message))
        {
            value = FirstString(message, "turn_id", "turnId");
        }
        return Clip(value, 128);
    }

    private static string ExtractError(IDictionary<string, object> data)
    {
        IDictionary<string, object> response;
        if (TryDictionary(data, "tool_response", out response))
        {
            var nested = FirstString(response, "error", "message", "stderr");
            if (!String.IsNullOrWhiteSpace(nested))
            {
                return Clip(nested, PromptPreviewLength);
            }
        }
        object rawResponse;
        if (data.TryGetValue("tool_response", out rawResponse) && rawResponse is string)
        {
            return Clip(StringValue(rawResponse), PromptPreviewLength);
        }
        return Clip(FirstString(data, "error", "message"), PromptPreviewLength);
    }

    private static void Send(IDictionary<string, object> payload)
    {
        var port = 57310;
        var configuredPort = Environment.GetEnvironmentVariable("ZCODE_STATUS_PORT");
        int parsedPort;
        if (Int32.TryParse(configuredPort, out parsedPort) && parsedPort > 0 && parsedPort <= 65535)
        {
            port = parsedPort;
        }
        var bytes = Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(payload));
        for (var attempt = 0; attempt < 2; attempt += 1)
        {
            try
            {
                var request = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + port + "/event");
                request.Method = "POST";
                request.ContentType = "application/json";
                request.ContentLength = bytes.Length;
                request.Timeout = 500;
                request.ReadWriteTimeout = 500;
                using (var stream = request.GetRequestStream())
                {
                    stream.Write(bytes, 0, bytes.Length);
                }
                using (var response = (HttpWebResponse)request.GetResponse())
                {
                    if ((int)response.StatusCode >= 200 && (int)response.StatusCode < 300)
                    {
                        return;
                    }
                }
            }
            catch
            {
                if (attempt == 0)
                {
                    Thread.Sleep(150);
                }
            }
        }
    }

    private static string WorkspaceName(string directory)
    {
        if (String.IsNullOrWhiteSpace(directory))
        {
            return "ZCode";
        }
        try
        {
            var trimmed = directory.TrimEnd('\\', '/');
            var name = Path.GetFileName(trimmed);
            return String.IsNullOrWhiteSpace(name) ? "ZCode" : name;
        }
        catch
        {
            return "ZCode";
        }
    }

    private static bool TryDictionary(IDictionary<string, object> source, string key, out IDictionary<string, object> value)
    {
        object raw;
        value = null;
        return source.TryGetValue(key, out raw) && (value = raw as IDictionary<string, object>) != null;
    }

    private static string FirstString(IDictionary<string, object> source, params string[] keys)
    {
        foreach (var key in keys)
        {
            object value;
            if (source.TryGetValue(key, out value))
            {
                var text = StringValue(value);
                if (!String.IsNullOrWhiteSpace(text))
                {
                    return text;
                }
            }
        }
        return String.Empty;
    }

    private static string StringValue(object value)
    {
        return value == null ? String.Empty : Convert.ToString(value).Trim();
    }

    private static string Clip(string value, int length)
    {
        var compact = Regex.Replace(value ?? String.Empty, @"\s+", " ").Trim();
        return compact.Length > length ? compact.Substring(0, length - 3) + "..." : compact;
    }

    private static byte[] Utf8(string value)
    {
        return Encoding.UTF8.GetBytes((value ?? String.Empty) + "\0");
    }

    private static string Utf8String(IntPtr value)
    {
        if (value == IntPtr.Zero)
        {
            return String.Empty;
        }
        var length = 0;
        while (Marshal.ReadByte(value, length) != 0)
        {
            length += 1;
        }
        var bytes = new byte[length];
        Marshal.Copy(value, bytes, 0, length);
        return Encoding.UTF8.GetString(bytes);
    }
}
