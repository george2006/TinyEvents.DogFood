using Npgsql;

internal static class PostgreSqlUpgradeDatabaseReset
{
    public static async ValueTask ExecuteAsync(
        UpgradeSettings settings,
        CancellationToken cancellationToken)
    {
        await using var connection = new NpgsqlConnection(
            settings.AdministrationConnectionString);
        await connection.OpenAsync(cancellationToken);
        await TerminateConnectionsAsync(
            connection,
            settings.DatabaseName,
            cancellationToken);

        var quotedDatabaseName =
            new NpgsqlCommandBuilder().QuoteIdentifier(settings.DatabaseName);
        await ExecuteAsync(
            connection,
            $"DROP DATABASE IF EXISTS {quotedDatabaseName};",
            cancellationToken);
        await ExecuteAsync(
            connection,
            $"CREATE DATABASE {quotedDatabaseName};",
            cancellationToken);
    }

    private static async ValueTask TerminateConnectionsAsync(
        NpgsqlConnection connection,
        string databaseName,
        CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT pg_terminate_backend(pid)
            FROM pg_stat_activity
            WHERE datname = @DatabaseName
              AND pid <> pg_backend_pid();
            """;

        await using var command = new NpgsqlCommand(sql, connection);
        command.Parameters.AddWithValue("DatabaseName", databaseName);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static async ValueTask ExecuteAsync(
        NpgsqlConnection connection,
        string sql,
        CancellationToken cancellationToken)
    {
        await using var command = new NpgsqlCommand(sql, connection);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
