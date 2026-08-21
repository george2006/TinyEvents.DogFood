namespace TinyEvents.Dogfood.Operations;

internal abstract class DogfoodConsumerAttemptRecorder
{
    public abstract ValueTask<int> RecordAsync(
        Guid operationId,
        string scenarioId,
        CancellationToken cancellationToken);
}
