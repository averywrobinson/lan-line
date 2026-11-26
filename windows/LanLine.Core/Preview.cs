namespace LanLine.Core;

public enum PreviewKind { Image, Text, Thumbnail }

/// <summary>
/// The Windows preview (beta.10; the Mac uses Quick Look): select a file card, press Space. Pictures show whole,
/// text and code show readable, anything else shows Explorer's large thumbnail with Open and Show in folder.
/// </summary>
public static class Preview
{
    static readonly HashSet<string> Images = new(StringComparer.OrdinalIgnoreCase)
        { "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "ico", "webp", "heic", "heif", "jxr" };
    static readonly HashSet<string> Texts = new(StringComparer.OrdinalIgnoreCase)
    {
        "txt", "md", "markdown", "log", "json", "jsonl", "csv", "tsv", "xml", "yaml", "yml", "ini", "cfg", "conf", "toml", "env",
        "cs", "csproj", "sln", "xaml", "swift", "py", "js", "mjs", "ts", "tsx", "jsx", "html", "htm", "css", "scss", "sh", "zsh",
        "ps1", "psm1", "bat", "cmd", "c", "h", "cpp", "hpp", "m", "java", "kt", "go", "rs", "rb", "php", "sql", "plist", "iss",
        "gitignore", "editorconfig", "dockerfile", "makefile", "srt", "vtt",
    };
    /// <summary>The most text shown (a longer file says it was cut).</summary>
    public const int MaxTextBytes = 256_000;

    public static PreviewKind Of(string name, bool isFolder)
    {
        if (isFolder) return PreviewKind.Thumbnail;
        var ext = Path.GetExtension(name).TrimStart('.');
        if (ext.Length == 0) ext = Path.GetFileName(name);   // "Dockerfile", "Makefile", ".gitignore"
        if (Images.Contains(ext)) return PreviewKind.Image;
        if (Texts.Contains(ext.TrimStart('.'))) return PreviewKind.Text;
        return PreviewKind.Thumbnail;
    }

    /// <summary>The next index when paging (arrow keys): stays inside 0…count-1, no wrap-around.</summary>
    public static int Step(int index, int count, int delta) => count == 0 ? -1 : Math.Clamp(index + delta, 0, count - 1);

    /// <summary>"2 of 5", or null for a single file.</summary>
    public static string? Position(int index, int count) => count > 1 ? $"{index + 1} of {count}" : null;
}
