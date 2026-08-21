namespace TinyEvents.Dogfood.Operations;

internal static class DogfoodStorageProviderSelector
{
    private const string StorageProviderVariable =
        "TINYEVENTS_DOGFOOD_STORAGE";

    public static IDogfoodStorageProvider Load()
    {
        var provider = Environment.GetEnvironmentVariable(
            StorageProviderVariable);

        if (string.Equals(provider, "sqlserver", StringComparison.OrdinalIgnoreCase))
        {
            return new SqlServerDogfoodStorageProvider();
        }

        if (string.Equals(provider, "postgresql", StringComparison.OrdinalIgnoreCase))
        {
            return new PostgreSqlDogfoodStorageProvider();
        }

        throw new InvalidOperationException(
            $"Environment variable '{StorageProviderVariable}' must be 'sqlserver' or 'postgresql'. Actual: '{provider ?? "not provided"}'.");
    }
}
