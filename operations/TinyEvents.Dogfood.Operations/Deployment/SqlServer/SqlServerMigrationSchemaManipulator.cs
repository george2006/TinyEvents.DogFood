using Microsoft.Data.SqlClient;

namespace TinyEvents.Dogfood.Operations;

internal sealed class SqlServerMigrationSchemaManipulator :
    IMigrationSchemaManipulator
{
    public async ValueTask RemoveOutboxTableAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        const string sql = "DROP TABLE dbo.TinyOutbox;";

        await ExecuteAsync(settings, sql, cancellationToken);
    }

    public async ValueTask ReplaceMigrationChecksumAsync(
        DogfoodSettings settings,
        string checksum,
        CancellationToken cancellationToken)
    {
        const string sql = """
            UPDATE dbo.TinyOutboxMigrations
            SET [Checksum] = @Checksum
            WHERE [Version] = 1;
            """;

        await using var connection = new SqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@Checksum", checksum);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static async ValueTask ExecuteAsync(
        DogfoodSettings settings,
        string sql,
        CancellationToken cancellationToken)
    {
        await using var connection = new SqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
