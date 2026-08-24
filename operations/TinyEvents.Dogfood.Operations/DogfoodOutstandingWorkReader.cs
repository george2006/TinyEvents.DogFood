namespace TinyEvents.Dogfood.Operations;

internal static class DogfoodOutstandingWorkReader
{
    public static ValueTask<bool> HasOutstandingMessagesAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken = default)
    {
        return settings.StorageProvider.HasOutstandingMessagesAsync(
            settings,
            cancellationToken);
    }

    public static ValueTask<int> CountOutstandingMessagesAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken = default)
    {
        return settings.StorageProvider.CountOutstandingMessagesAsync(
            settings,
            cancellationToken);
    }
}
