namespace TinyEvents.Dogfood.Operations;

internal sealed record ScenarioObservation(
    int BusinessOperations,
    int OutboxMessages,
    int PendingMessages,
    int ProcessingMessages,
    int ProcessedMessages,
    int FailedMessages,
    int Effects,
    int DuplicateEffects);
