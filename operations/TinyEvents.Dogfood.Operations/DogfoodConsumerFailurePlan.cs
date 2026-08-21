namespace TinyEvents.Dogfood.Operations;

internal sealed class DogfoodConsumerFailurePlan(
    DogfoodConsumerAttemptRecorder attempts)
{
    public async ValueTask RejectWhenPlannedAsync(
        OperationalEvent @event,
        CancellationToken cancellationToken)
    {
        var failuresBeforeSuccess = GetFailuresBeforeSuccess(@event);

        if (failuresBeforeSuccess == 0)
        {
            return;
        }

        var attemptNumber = await attempts.RecordAsync(
            @event.OperationId,
            @event.ScenarioId,
            cancellationToken);

        if (attemptNumber <= failuresBeforeSuccess)
        {
            throw new DogfoodPlannedFailureException(
                $"{@event.ScenarioId} rejects consumer attempt {attemptNumber}.");
        }
    }

    private static int GetFailuresBeforeSuccess(OperationalEvent @event)
    {
        return @event.ScenarioId switch
        {
            "TE-W09" => 1,
            "TE-W10-retry" => 2,
            _ => 0
        };
    }
}

internal sealed class DogfoodPlannedFailureException(string message)
    : Exception(message);
