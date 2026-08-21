namespace TinyEvents.Dogfood.Operations;

internal sealed class DogfoodConsumerFailurePlan(
    DogfoodConsumerAttemptRecorder attempts,
    ConsumerFailureInjection injection)
{
    public async ValueTask RejectWhenPlannedAsync(
        Guid operationId,
        string scenarioId,
        CancellationToken cancellationToken)
    {
        if (!injection.Targets(scenarioId))
        {
            return;
        }

        var attemptNumber = await attempts.RecordAsync(
            operationId,
            scenarioId,
            cancellationToken);

        if (attemptNumber <= injection.RejectedAttemptCount)
        {
            throw new DogfoodPlannedFailureException(
                $"{scenarioId} rejects consumer attempt {attemptNumber}.");
        }
    }
}

internal sealed class DogfoodPlannedFailureException(string message)
    : Exception(message);
