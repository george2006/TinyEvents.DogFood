using TinyEvents;

namespace TinyEvents.Dogfood.Operations;

internal sealed class OperationalEventConsumer(
    DogfoodEffectRecorder effects,
    ConsumerDelay delay)
    : IEventConsumer<OperationalEvent>
{
    public async ValueTask ConsumeAsync(
        OperationalEvent @event,
        CancellationToken cancellationToken)
    {
        if (delay.Value > TimeSpan.Zero)
        {
            await Task.Delay(delay.Value, cancellationToken);
        }

        await effects.RecordAsync(
            @event.OperationId,
            @event.ScenarioId,
            cancellationToken);
    }
}
