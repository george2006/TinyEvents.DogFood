using Microsoft.Data.SqlClient;

namespace TinyEvents.Dogfood.Operations;

internal static class SqlServerDogfoodSettingsLoader
{
    private const string ConnectionStringVariable =
        "TINYEVENTS_DOGFOOD_SQLSERVER";

    public static DogfoodSettings Load(
        IDogfoodStorageProvider storageProvider)
    {
        var connectionString = LoadConnectionString();
        var builder = new SqlConnectionStringBuilder(connectionString);
        var databaseName =
            DogfoodDatabaseName.RequireValid(builder.InitialCatalog);
        builder.InitialCatalog = "master";

        return new DogfoodSettings(
            storageProvider,
            connectionString,
            builder.ConnectionString,
            databaseName);
    }

    private static string LoadConnectionString()
    {
        var connectionString =
            Environment.GetEnvironmentVariable(ConnectionStringVariable);

        if (string.IsNullOrWhiteSpace(connectionString))
        {
            throw new InvalidOperationException(
                $"Environment variable '{ConnectionStringVariable}' is required.");
        }

        return connectionString;
    }
}
