namespace TinyEvents.Dogfood.Operations;

internal static class DogfoodObservationReader
{
    public static ValueTask<ScenarioObservation> ReadAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken = default)
    {
        return settings.StorageProvider.ReadObservationAsync(
            settings,
            cancellationToken);
    }
}
