namespace TinyEvents.Dogfood.Operations;

internal sealed class DogfoodConsumerFailurePlan(
    DogfoodConsumerAttemptRecorder attempts)
{
    public async ValueTask RejectWhenPlannedAsync(
        OperationalEvent @event,
        CancellationToken cancellationToken)
    {
        if (!IsRestartRetryScenario(@event))
        {
            return;
        }

        var attemptNumber = await attempts.RecordAsync(
            @event.OperationId,
            @event.ScenarioId,
            cancellationToken);

        if (IsFirstAttempt(attemptNumber))
        {
            throw new DogfoodPlannedFailureException(
                "TE-W09 rejects its first consumer invocation.");
        }
    }

    private static bool IsRestartRetryScenario(OperationalEvent @event)
    {
        return @event.ScenarioId == "TE-W09";
    }

    private static bool IsFirstAttempt(int attemptNumber)
    {
        return attemptNumber == 1;
    }
}

internal sealed class DogfoodPlannedFailureException(string message)
    : Exception(message);

