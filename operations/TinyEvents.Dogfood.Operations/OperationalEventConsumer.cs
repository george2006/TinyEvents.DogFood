using TinyEvents;

namespace TinyEvents.Dogfood.Operations;

internal sealed class OperationalEventConsumer(
    DogfoodConsumerFailurePlan failurePlan,
    DogfoodEffectRecorder effects,
    ConsumerExecutionTiming timing)
    : IEventConsumer<OperationalEvent>
{
    public async ValueTask ConsumeAsync(
        OperationalEvent @event,
        CancellationToken cancellationToken)
    {
        await failurePlan.RejectWhenPlannedAsync(@event, cancellationToken);

        if (timing.BeforeEffectDelay > TimeSpan.Zero)
        {
            await Task.Delay(timing.BeforeEffectDelay, cancellationToken);
        }

        await effects.RecordAsync(
            @event.OperationId,
            @event.ScenarioId,
            cancellationToken);

        if (timing.AfterEffectDelay > TimeSpan.Zero)
        {
            await Task.Delay(timing.AfterEffectDelay, cancellationToken);
        }
    }
}
