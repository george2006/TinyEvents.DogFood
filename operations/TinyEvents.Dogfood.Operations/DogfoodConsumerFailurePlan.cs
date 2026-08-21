namespace TinyEvents.Dogfood.Operations;

internal sealed class DogfoodConsumerFailurePlan(
    DogfoodConsumerAttemptRecorder attempts,
    ConsumerFailureInjection injection)
{
    public async ValueTask RejectWhenPlannedAsync(
        OperationalEvent @event,
        CancellationToken cancellationToken)
    {
        if (!injection.Targets(@event.ScenarioId))
        {
            return;
        }

        var attemptNumber = await attempts.RecordAsync(
            @event.OperationId,
            @event.ScenarioId,
            cancellationToken);

        if (attemptNumber <= injection.RejectedAttemptCount)
        {
            throw new DogfoodPlannedFailureException(
                $"{@event.ScenarioId} rejects consumer attempt {attemptNumber}.");
        }
    }
}

internal sealed class DogfoodPlannedFailureException(string message)
    : Exception(message);
