using Microsoft.Data.SqlClient;

internal static class SqlServerUpgradeDatabaseReset
{
    public static async ValueTask ExecuteAsync(
        UpgradeSettings settings,
        CancellationToken cancellationToken)
    {
        await using var connection = new SqlConnection(
            settings.AdministrationConnectionString);
        await connection.OpenAsync(cancellationToken);

        var quotedDatabaseName = new SqlCommandBuilder().QuoteIdentifier(settings.DatabaseName);
        var sql = $"""
            IF DB_ID(@DatabaseName) IS NOT NULL
            BEGIN
                ALTER DATABASE {quotedDatabaseName} SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
                DROP DATABASE {quotedDatabaseName};
            END;

            CREATE DATABASE {quotedDatabaseName};
            """;

        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@DatabaseName", settings.DatabaseName);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
