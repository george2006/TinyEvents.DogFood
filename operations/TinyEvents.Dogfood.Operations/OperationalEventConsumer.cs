using TinyEvents;

namespace TinyEvents.Dogfood.Operations;

internal sealed class OperationalEventConsumer(
    DogfoodEffectRecorder effects)
    : IEventConsumer<OperationalEvent>
{
    public ValueTask ConsumeAsync(
        OperationalEvent @event,
        CancellationToken cancellationToken)
    {
        return effects.RecordAsync(
            @event.OperationId,
            @event.ScenarioId,
            cancellationToken);
    }
}
