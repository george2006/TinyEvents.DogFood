using Microsoft.Data.SqlClient;

namespace TinyEvents.Dogfood.Operations;

internal static class DogfoodMigrationObservationReader
{
    public static async ValueTask<MigrationObservation> ReadAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken = default)
    {
        const string sql = """
            SELECT
                CASE WHEN OBJECT_ID(N'dbo.TinyOutbox', N'U') IS NULL THEN 0 ELSE 1 END,
                CASE WHEN OBJECT_ID(N'dbo.TinyOutboxMigrations', N'U') IS NULL THEN 0 ELSE 1 END;

            IF OBJECT_ID(N'dbo.TinyOutboxMigrations', N'U') IS NOT NULL
            BEGIN
                SELECT [Version], [Name], [Checksum], [AppliedAtUtc]
                FROM dbo.TinyOutboxMigrations
                ORDER BY [Version];
            END
            ELSE
            BEGIN
                SELECT
                    CAST(NULL AS BIGINT) AS [Version],
                    CAST(NULL AS NVARCHAR(256)) AS [Name],
                    CAST(NULL AS CHAR(64)) AS [Checksum],
                    CAST(NULL AS DATETIMEOFFSET) AS [AppliedAtUtc]
                WHERE 1 = 0;
            END;
            """;

        await using var connection = new SqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        await reader.ReadAsync(cancellationToken);
        var outboxTableExists = reader.GetInt32(0) == 1;
        var historyTableExists = reader.GetInt32(1) == 1;

        await reader.NextResultAsync(cancellationToken);
        var history = new List<MigrationHistoryEntry>();

        while (await reader.ReadAsync(cancellationToken))
        {
            history.Add(new MigrationHistoryEntry(
                reader.GetInt64(0),
                reader.GetString(1),
                reader.GetString(2),
                reader.GetFieldValue<DateTimeOffset>(3)));
        }

        return new MigrationObservation(
            outboxTableExists,
            historyTableExists,
            history);
    }
}
