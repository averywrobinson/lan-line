namespace LanLine.App;

/// <summary>One paired computer as the window shows it.</summary>
sealed record PartnerInfo(string Id, string Name, bool Up = false);
