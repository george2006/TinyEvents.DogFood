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
        await failurePlan.RejectWhenPlannedAsync(
            @event.OperationId,
            @event.ScenarioId,
            cancellationToken);

        var executionTiming = timing.ResolveFor(@event.ScenarioId);

        if (executionTiming.BeforeEffectDelay > TimeSpan.Zero)
        {
            await Task.Delay(
                executionTiming.BeforeEffectDelay,
                cancellationToken);
        }

        await effects.RecordAsync(
            @event.OperationId,
            @event.ScenarioId,
            cancellationToken);

        if (executionTiming.AfterEffectDelay > TimeSpan.Zero)
        {
            await Task.Delay(
                executionTiming.AfterEffectDelay,
                cancellationToken);
        }
    }
}
