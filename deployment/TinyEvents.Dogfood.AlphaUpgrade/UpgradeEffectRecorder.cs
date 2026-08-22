public abstract class UpgradeEffectRecorder
{
    public abstract ValueTask RecordAsync(
        Guid operationId,
        string messageState,
        string workerId,
        CancellationToken cancellationToken);
}
