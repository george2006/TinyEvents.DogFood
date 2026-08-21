namespace TinyEvents.Dogfood.Operations;

internal sealed record MigrationObservation(
    bool OutboxTableExists,
    bool HistoryTableExists,
    IReadOnlyList<MigrationHistoryEntry> History);

internal sealed record MigrationHistoryEntry(
    long Version,
    string Name,
    string Checksum,
    DateTimeOffset AppliedAtUtc);
