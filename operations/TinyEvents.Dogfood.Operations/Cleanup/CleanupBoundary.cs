namespace TinyEvents.Dogfood.Operations;

internal sealed record CleanupBoundary(
    DateTimeOffset CutoffUtc,
    Guid EligibleProcessedId,
    Guid BoundaryProcessedId,
    Guid RecentProcessedId,
    Guid PendingId,
    Guid ProcessingId,
    Guid FailedId)
{
    public Guid[] MessageIds =>
    [
        EligibleProcessedId,
        BoundaryProcessedId,
        RecentProcessedId,
        PendingId,
        ProcessingId,
        FailedId
    ];
}

internal sealed record CleanupBoundaryRow(
    Guid Id,
    bool Exists,
    string? Status,
    DateTimeOffset? ProcessedAtUtc);

internal sealed record CleanupBoundaryObservation(
    CleanupBoundaryRow EligibleProcessed,
    CleanupBoundaryRow BoundaryProcessed,
    CleanupBoundaryRow RecentProcessed,
    CleanupBoundaryRow Pending,
    CleanupBoundaryRow Processing,
    CleanupBoundaryRow Failed);

internal sealed record CleanupBoundaryResult(
    DateTimeOffset CutoffUtc,
    int DeletedCount,
    CleanupBoundaryObservation AfterCleanup);
