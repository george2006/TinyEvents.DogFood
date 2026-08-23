namespace TinyEvents.Dogfood.Operations;

internal sealed record CleanupPopulationResult(
    DateTimeOffset CutoffUtc,
    int MessageCount);

internal sealed record CleanupBatchResult(
    int ProcessId,
    DateTimeOffset StartedAtUtc,
    DateTimeOffset CompletedAtUtc,
    int RequestedBatchSize,
    int DeletedCount);
