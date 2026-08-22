namespace TinyEvents.Dogfood.Operations;

internal sealed record PublishingLoadResult(
    int TargetRequestsPerSecond,
    int DurationSeconds,
    int AttemptedRequests,
    int CommittedRequests,
    int FailedRequests,
    double CompletionDurationMilliseconds,
    double CommittedRequestsPerSecond,
    double CommittedP50LatencyMilliseconds,
    double CommittedP95LatencyMilliseconds,
    double CommittedP99LatencyMilliseconds,
    IReadOnlyDictionary<string, int> ErrorTypes);
