using Npgsql;

namespace TinyEvents.Dogfood.Operations;

internal sealed class PostgreSqlMigrationSchemaManipulator :
    IMigrationSchemaManipulator
{
    public async ValueTask RemoveOutboxTableAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        const string sql = "DROP TABLE \"TinyOutbox\";";

        await ExecuteAsync(settings, sql, cancellationToken);
    }

    public async ValueTask ReplaceMigrationChecksumAsync(
        DogfoodSettings settings,
        string checksum,
        CancellationToken cancellationToken)
    {
        const string sql = """
            UPDATE "TinyOutboxMigrations"
            SET "Checksum" = @Checksum
            WHERE "Version" = 1;
            """;

        await using var connection = new NpgsqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new NpgsqlCommand(sql, connection);
        command.Parameters.AddWithValue("Checksum", checksum);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static async ValueTask ExecuteAsync(
        DogfoodSettings settings,
        string sql,
        CancellationToken cancellationToken)
    {
        await using var connection = new NpgsqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new NpgsqlCommand(sql, connection);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
