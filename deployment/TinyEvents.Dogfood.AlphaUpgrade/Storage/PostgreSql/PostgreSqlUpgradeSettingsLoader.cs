using Npgsql;

internal static class PostgreSqlUpgradeSettingsLoader
{
    private const string ConnectionStringVariable =
        "TINYEVENTS_DOGFOOD_UPGRADE_POSTGRESQL";
    private const string DatabaseNamePrefix = "TinyEventsDogfoodUpgrade";

    public static UpgradeSettings Load()
    {
        var connectionString = Environment.GetEnvironmentVariable(
            ConnectionStringVariable);

        if (string.IsNullOrWhiteSpace(connectionString))
        {
            throw new InvalidOperationException(
                $"Environment variable {ConnectionStringVariable} is required.");
        }

        var builder = new NpgsqlConnectionStringBuilder(connectionString);
        var databaseName = builder.Database
            ?? throw new InvalidOperationException(
                "PostgreSQL database name is required.");
        RequireDogfoodDatabaseName(databaseName);

        builder.Database = "postgres";
        return new UpgradeSettings(
            connectionString,
            databaseName,
            builder.ConnectionString);
    }

    private static void RequireDogfoodDatabaseName(string databaseName)
    {
        var isDogfoodDatabase =
            databaseName.StartsWith(DatabaseNamePrefix, StringComparison.Ordinal) &&
            databaseName.All(character =>
                char.IsLetterOrDigit(character) || character == '_');

        if (!isDogfoodDatabase)
        {
            throw new InvalidOperationException(
                $"Dogfood database name must start with '{DatabaseNamePrefix}' and contain only letters, numbers, or underscores. Actual: '{databaseName}'.");
        }
    }
}
