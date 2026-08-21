namespace TinyEvents.Dogfood.Operations;

internal sealed record MultiConsumerOperationalEvent(
    Guid OperationId,
    string ScenarioId);
