using TinyEvents;

namespace TinyEvents.Dogfood.Operations;

internal sealed class EarlierRecordingMultiConsumerEventConsumer(
    DogfoodEffectRecorder effects)
    : IEventConsumer<MultiConsumerOperationalEvent>
{
    public ValueTask ConsumeAsync(
        MultiConsumerOperationalEvent @event,
        CancellationToken cancellationToken)
    {
        return effects.RecordAsync(
            @event.OperationId,
            @event.ScenarioId,
            cancellationToken);
    }
}
