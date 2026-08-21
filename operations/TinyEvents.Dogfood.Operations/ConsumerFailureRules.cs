namespace TinyEvents.Dogfood.Operations;

internal sealed class ConsumerFailureRules
{
    private readonly IReadOnlyDictionary<string, int> rejectedAttemptsByScenario;

    public ConsumerFailureRules(
        IEnumerable<ConsumerFailureRule> rules)
    {
        rejectedAttemptsByScenario = rules.ToDictionary(
            rule => rule.ScenarioId,
            rule => rule.RejectedAttemptCount,
            StringComparer.Ordinal);
    }

    public static ConsumerFailureRules None { get; } = new([]);

    public int GetRejectedAttemptCount(string scenarioId)
    {
        return rejectedAttemptsByScenario.GetValueOrDefault(scenarioId);
    }
}

internal sealed record ConsumerFailureRule(
    string ScenarioId,
    int RejectedAttemptCount);
