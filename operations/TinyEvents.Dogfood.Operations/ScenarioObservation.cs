namespace TinyEvents.Dogfood.Operations;

internal sealed record ScenarioObservation(
    DateTimeOffset DatabaseUtcNow,
    DateTimeOffset? EarliestClaimExpiresAtUtc,
    DateTimeOffset? EarliestNextAttemptAtUtc,
    string? TerminalError,
    int BusinessOperations,
    int OutboxMessages,
    int PendingMessages,
    int ProcessingMessages,
    int ProcessedMessages,
    int FailedMessages,
    int FailedAttempts,
    int Effects,
    int DuplicateEffects,
    int ConsumerAttempts,
    DateTimeOffset? LatestConsumerAttemptAtUtc,
    IReadOnlyDictionary<string, int> WorkerClaims,
    IReadOnlyDictionary<string, int> WorkerEffects,
    IReadOnlyDictionary<string, int> WorkerAttempts,
    IReadOnlyDictionary<string, int> ProcessEffects,
    IReadOnlyDictionary<string, int> ScenarioEffects,
    IReadOnlyDictionary<string, int> ScenarioAttempts);
