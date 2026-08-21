using TinyEvents;

namespace TinyEvents.Dogfood.Operations;

internal sealed class LaterRejectingMultiConsumerEventConsumer(
    DogfoodConsumerFailurePlan failurePlan)
    : IEventConsumer<MultiConsumerOperationalEvent>
{
    public ValueTask ConsumeAsync(
        MultiConsumerOperationalEvent @event,
        CancellationToken cancellationToken)
    {
        return failurePlan.RejectWhenPlannedAsync(
            @event.OperationId,
            @event.ScenarioId,
            cancellationToken);
    }
}
