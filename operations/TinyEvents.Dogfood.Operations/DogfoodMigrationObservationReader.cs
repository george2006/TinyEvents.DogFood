namespace TinyEvents.Dogfood.Operations;

internal static class DogfoodMigrationObservationReader
{
    public static ValueTask<MigrationObservation> ReadAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken = default)
    {
        return settings.StorageProvider.ReadMigrationObservationAsync(
            settings,
            cancellationToken);
    }
}
