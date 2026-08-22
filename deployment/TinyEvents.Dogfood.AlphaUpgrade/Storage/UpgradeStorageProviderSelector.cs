internal static class UpgradeStorageProviderSelector
{
    private const string StorageProviderVariable =
        "TINYEVENTS_DOGFOOD_UPGRADE_STORAGE";

    public static IUpgradeStorageProvider Load()
    {
        var provider = Environment.GetEnvironmentVariable(
            StorageProviderVariable);

        if (string.Equals(provider, "sqlserver", StringComparison.OrdinalIgnoreCase))
        {
            return new SqlServerUpgradeStorageProvider();
        }

        if (string.Equals(provider, "postgresql", StringComparison.OrdinalIgnoreCase))
        {
            return new PostgreSqlUpgradeStorageProvider();
        }

        throw new InvalidOperationException(
            $"Environment variable '{StorageProviderVariable}' must be 'sqlserver' or 'postgresql'. Actual: '{provider ?? "not provided"}'.");
    }
}
