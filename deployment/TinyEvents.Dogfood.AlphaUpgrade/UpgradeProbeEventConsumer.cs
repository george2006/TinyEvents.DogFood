using TinyEvents;
using TinyEvents.Dogfood.AlphaUpgrade.Contracts;

public sealed class UpgradeProbeEventConsumer(
    UpgradeEffectRecorder effects,
    UpgradeWorkerIdentity workerIdentity)
    : IEventConsumer<UpgradeProbeEvent>
{
    public ValueTask ConsumeAsync(
        UpgradeProbeEvent @event,
        CancellationToken cancellationToken)
    {
        return effects.RecordAsync(
            @event.OperationId,
            @event.State,
            workerIdentity.WorkerId,
            cancellationToken);
    }
}
