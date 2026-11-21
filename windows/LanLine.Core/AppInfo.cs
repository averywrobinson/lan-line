using System.Reflection;

namespace LanLine.Core;

public static class AppInfo
{
    /// <summary>"0.9.0-beta.6": the entry assembly's informational version without the "+commit" suffix the SDK adds.</summary>
    public static string Version
    {
        get
        {
            var entry = Assembly.GetEntryAssembly();
            if (entry?.GetName().Name != "Lan-Line") return "";   // e.g. LanLine.Tests: no version, no update notices
            var v = entry.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "";
            var plus = v.IndexOf('+');
            return plus >= 0 ? v[..plus] : v;
        }
    }
}
