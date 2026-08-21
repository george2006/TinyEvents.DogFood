using Npgsql;

namespace TinyEvents.Dogfood.Operations;

internal static class PostgreSqlDogfoodSettingsLoader
{
    private const string ConnectionStringVariable =
        "TINYEVENTS_DOGFOOD_POSTGRESQL";

    public static DogfoodSettings Load(
        IDogfoodStorageProvider storageProvider)
    {
        var connectionString = LoadConnectionString();
        var builder = new NpgsqlConnectionStringBuilder(connectionString);
        var databaseName =
            DogfoodDatabaseName.RequireValid(builder.Database);
        builder.Database = "postgres";

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
