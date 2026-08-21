namespace TinyEvents.Dogfood.Operations;

internal sealed record ConsumerFailureInjection(
    string? TargetScenarioId,
    int RejectedAttemptCount)
{
    public static ConsumerFailureInjection None { get; } = new(null, 0);

    public bool Targets(string scenarioId)
    {
        var hasRejectedAttempts = RejectedAttemptCount > 0;
        var targetsScenario = string.Equals(
            TargetScenarioId,
            scenarioId,
            StringComparison.Ordinal);

        return hasRejectedAttempts && targetsScenario;
    }
}
