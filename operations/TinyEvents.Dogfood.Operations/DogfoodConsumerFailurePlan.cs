namespace TinyEvents.Dogfood.Operations;

internal sealed class DogfoodConsumerFailurePlan(
    DogfoodConsumerAttemptRecorder attempts,
    ConsumerFailureRules rules)
{
    public async ValueTask RejectWhenPlannedAsync(
        Guid operationId,
        string scenarioId,
        CancellationToken cancellationToken)
    {
        var rejectedAttemptCount = rules.GetRejectedAttemptCount(scenarioId);

        if (rejectedAttemptCount == 0)
        {
            return;
        }

        var attemptNumber = await attempts.RecordAsync(
            operationId,
            scenarioId,
            cancellationToken);

        if (attemptNumber <= rejectedAttemptCount)
        {
            throw new DogfoodPlannedFailureException(
                $"{scenarioId} rejects consumer attempt {attemptNumber}.");
        }
    }
}

internal sealed class DogfoodPlannedFailureException(string message)
    : Exception(message);
