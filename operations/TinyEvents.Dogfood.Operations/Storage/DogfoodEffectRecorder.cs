namespace TinyEvents.Dogfood.Operations;

internal abstract class DogfoodEffectRecorder
{
    public abstract ValueTask RecordAsync(
        Guid operationId,
        string scenarioId,
        CancellationToken cancellationToken);
}
