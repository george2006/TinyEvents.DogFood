using Microsoft.Data.SqlClient;

namespace TinyEvents.Dogfood.Operations;

internal sealed record DogfoodSettings(
    DogfoodStorageProvider StorageProvider,
    string ConnectionString,
    string AdministrationConnectionString,
    string DatabaseName)
{
    private const string StorageProviderVariable = "TINYEVENTS_DOGFOOD_STORAGE";
    private const string ConnectionStringVariable = "TINYEVENTS_DOGFOOD_SQLSERVER";
    private const string DatabaseNamePrefix = "TinyEventsDogfood";

    public static DogfoodSettings Load()
    {
        var storageProvider = LoadStorageProvider();
        var connectionString = Environment.GetEnvironmentVariable(ConnectionStringVariable);

        if (string.IsNullOrWhiteSpace(connectionString))
        {
            throw new InvalidOperationException(
                $"Environment variable '{ConnectionStringVariable}' is required.");
        }

        var builder = new SqlConnectionStringBuilder(connectionString);
        var databaseName = builder.InitialCatalog;

        if (!IsDogfoodDatabaseName(databaseName))
        {
            throw new InvalidOperationException(
                $"Dogfood database name must start with '{DatabaseNamePrefix}' and contain only letters, numbers, or underscores. Actual: '{databaseName}'.");
        }

        builder.InitialCatalog = "master";

        return new DogfoodSettings(
            storageProvider,
            connectionString,
            builder.ConnectionString,
            databaseName);
    }

    private static DogfoodStorageProvider LoadStorageProvider()
    {
        var provider = Environment.GetEnvironmentVariable(StorageProviderVariable);

        if (string.Equals(provider, "sqlserver", StringComparison.OrdinalIgnoreCase))
        {
            return DogfoodStorageProvider.SqlServer;
        }

        throw new InvalidOperationException(
            $"Environment variable '{StorageProviderVariable}' must be 'sqlserver'. Actual: '{provider ?? "not provided"}'.");
    }

    private static bool IsDogfoodDatabaseName(string databaseName)
    {
        return !string.IsNullOrWhiteSpace(databaseName) &&
            databaseName.StartsWith(DatabaseNamePrefix, StringComparison.Ordinal) &&
            databaseName.All(character => char.IsLetterOrDigit(character) || character == '_');
    }
}
