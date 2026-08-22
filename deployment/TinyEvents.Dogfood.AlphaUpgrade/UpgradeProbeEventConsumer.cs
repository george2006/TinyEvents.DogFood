using TinyEvents;
using TinyEvents.Dogfood.AlphaUpgrade.Contracts;

public sealed class UpgradeProbeEventConsumer(
    UpgradeEffectRecorder effects,
    UpgradeWorkerIdentity workerIdentity)
    : IEventConsumer<UpgradeProbeEvent>
{
    public async ValueTask ConsumeAsync(
        UpgradeProbeEvent @event,
        CancellationToken cancellationToken)
    {
        await Task.Delay(workerIdentity.EffectDelay, cancellationToken);
        await effects.RecordAsync(
            @event.OperationId,
            @event.State,
            workerIdentity.WorkerId,
            cancellationToken);
    }
}
