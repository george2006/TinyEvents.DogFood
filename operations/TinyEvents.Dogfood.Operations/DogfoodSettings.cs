using Microsoft.Data.SqlClient;

namespace TinyEvents.Dogfood.Operations;

internal sealed record DogfoodSettings(
    string ConnectionString,
    string MasterConnectionString,
    string DatabaseName)
{
    private const string ConnectionStringVariable = "TINYEVENTS_DOGFOOD_SQLSERVER";
    private const string DatabaseNamePrefix = "TinyEventsDogfood";

    public static DogfoodSettings Load()
    {
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
            connectionString,
            builder.ConnectionString,
            databaseName);
    }

    private static bool IsDogfoodDatabaseName(string databaseName)
    {
        return !string.IsNullOrWhiteSpace(databaseName) &&
            databaseName.StartsWith(DatabaseNamePrefix, StringComparison.Ordinal) &&
            databaseName.All(character => char.IsLetterOrDigit(character) || character == '_');
    }
}
