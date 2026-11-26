namespace LanLine.Core;

/// <summary>Windows starts <c>Lan-Line.exe --url "LINK"</c> for a lanline: link (a notification's button, or any
/// page or document that names the scheme). The link is outside text: a raw quote in it can split the command
/// line into more arguments. So a launch that begins with <c>--url</c> is only ever that link; nothing after it
/// is read as a flag (no <c>--debug-log</c>, <c>--downloads</c>, <c>--headless</c> …).</summary>
public static class LaunchArgs
{
    public static string[] LinkOnly(string[] args) =>
        args.Length > 0 && args[0] == "--url" ? (args.Length >= 2 ? [args[0], args[1]] : []) : args;
}
