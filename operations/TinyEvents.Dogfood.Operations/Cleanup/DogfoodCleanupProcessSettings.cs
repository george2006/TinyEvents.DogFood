namespace TinyEvents.Dogfood.Operations;

internal sealed record DogfoodCleanupProcessSettings(
    TimeSpan ProcessedRetention,
    int BatchSize,
    TimeSpan Interval);
