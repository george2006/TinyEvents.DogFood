namespace TinyEvents.Dogfood.Operations;

internal static class DogfoodDatabaseReset
{
    public static async ValueTask ExecuteAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken = default)
    {
        await settings.StorageProvider.ResetAsync(
            settings,
            cancellationToken);
    }
}
