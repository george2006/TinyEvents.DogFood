using Microsoft.Data.SqlClient;

internal sealed record UpgradeSettings(
    string ConnectionString,
    string DatabaseName,
    string MasterConnectionString)
{
    private const string ConnectionStringVariable = "TINYEVENTS_DOGFOOD_UPGRADE_SQLSERVER";
    private const string DatabaseNamePrefix = "TinyEventsDogfoodUpgrade";

    public static UpgradeSettings Load()
    {
        var connectionString = Environment.GetEnvironmentVariable(ConnectionStringVariable);

        if (string.IsNullOrWhiteSpace(connectionString))
        {
            throw new InvalidOperationException(
                $"Environment variable {ConnectionStringVariable} is required.");
        }

        var builder = new SqlConnectionStringBuilder(connectionString);
        var databaseName = builder.InitialCatalog;

        if (!IsDogfoodDatabaseName(databaseName))
        {
            throw new InvalidOperationException(
                $"Dogfood database name must start with '{DatabaseNamePrefix}' and contain only letters, numbers, or underscores. Actual: '{databaseName}'.");
        }

        builder.InitialCatalog = "master";
        return new UpgradeSettings(
            connectionString,
            databaseName,
            builder.ConnectionString);
    }

    private static bool IsDogfoodDatabaseName(string databaseName)
    {
        return !string.IsNullOrWhiteSpace(databaseName) &&
            databaseName.StartsWith(DatabaseNamePrefix, StringComparison.Ordinal) &&
            databaseName.All(character => char.IsLetterOrDigit(character) || character == '_');
    }
}
