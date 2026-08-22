namespace TinyEvents.Dogfood.Operations;

internal static class DogfoodStorageObservationReader
{
    public static ValueTask<StorageObservation> ReadAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken = default)
    {
        return settings.StorageProvider.ReadStorageObservationAsync(
            settings,
            cancellationToken);
    }
}
