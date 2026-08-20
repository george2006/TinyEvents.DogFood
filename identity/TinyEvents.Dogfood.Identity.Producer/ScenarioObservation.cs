internal sealed record ScenarioObservation(
    string? EventType,
    string? Status,
    int AttemptCount,
    string? LastError,
    int EffectCount,
    string? ConsumerName)
{
    public static readonly ScenarioObservation Empty = new(null, null, 0, null, 0, null);
}
