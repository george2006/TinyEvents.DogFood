public abstract class UpgradeEffectRecorder
{
    public abstract ValueTask RecordAsync(
        string messageState,
        CancellationToken cancellationToken);
}
