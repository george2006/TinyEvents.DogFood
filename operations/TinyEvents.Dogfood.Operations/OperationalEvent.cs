namespace TinyEvents.Dogfood.Operations;

internal sealed record OperationalEvent(
    Guid OperationId,
    string ScenarioId,
    string Content);
