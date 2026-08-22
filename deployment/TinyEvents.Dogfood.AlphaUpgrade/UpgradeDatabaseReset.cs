using Microsoft.Data.SqlClient;

internal static class UpgradeDatabaseReset
{
    public static async Task ExecuteAsync(UpgradeSettings settings)
    {
        await using var connection = new SqlConnection(settings.MasterConnectionString);
        await connection.OpenAsync();

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
        await command.ExecuteNonQueryAsync();
    }
}
