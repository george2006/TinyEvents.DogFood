using Microsoft.Data.SqlClient;

namespace TinyEvents.Dogfood.Operations;

internal static class SqlServerDogfoodStorageObservationReader
{
    public static async ValueTask<StorageObservation> ReadAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT
                COUNT_BIG(*),
                COALESCE(SUM(CONVERT(BIGINT, DATALENGTH(Payload))), 0)
            FROM dbo.TinyOutbox;

            SELECT
                COALESCE(SUM(CASE
                    WHEN index_id IN (0, 1) THEN reserved_page_count
                    ELSE 0
                END), 0) * 8192,
                COALESCE(SUM(CASE
                    WHEN index_id > 1 THEN reserved_page_count
                    ELSE 0
                END), 0) * 8192,
                COALESCE(SUM(reserved_page_count), 0) * 8192
            FROM sys.dm_db_partition_stats
            WHERE object_id = OBJECT_ID(N'dbo.TinyOutbox');
            """;

        await using var connection = new SqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        await reader.ReadAsync(cancellationToken);
        var rowCount = reader.GetInt64(0);
        var payloadBytes = reader.GetInt64(1);

        await reader.NextResultAsync(cancellationToken);
        await reader.ReadAsync(cancellationToken);
        return new StorageObservation(
            rowCount,
            payloadBytes,
            reader.GetInt64(0),
            reader.GetInt64(1),
            reader.GetInt64(2));
    }
}
