using TinyEvents;
using TinyEvents.Dogfood.AlphaUpgrade.Contracts;

public sealed class UpgradeProbeEventConsumer(UpgradeEffectRecorder effects)
    : IEventConsumer<UpgradeProbeEvent>
{
    public ValueTask ConsumeAsync(
        UpgradeProbeEvent @event,
        CancellationToken cancellationToken)
    {
        return effects.RecordAsync(@event.State, cancellationToken);
    }
}
