using Microsoft.Data.SqlClient;

namespace TinyEvents.Dogfood.Operations;

internal static class SqlServerDogfoodStorageObservationReader
{
    private const int DeadlockVictimErrorNumber = 1205;
    private const int MaximumAttempts = 3;

    public static async ValueTask<StorageObservation> ReadAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        for (var attempt = 1; attempt <= MaximumAttempts; attempt++)
        {
            try
            {
                return await ReadOnceAsync(settings, cancellationToken);
            }
            catch (SqlException exception) when (ShouldRetry(exception, attempt))
            {
                await Task.Delay(TimeSpan.FromMilliseconds(50), cancellationToken);
            }
        }

        throw new InvalidOperationException("The SQL Server storage observation retry loop ended unexpectedly.");
    }

    private static bool ShouldRetry(SqlException exception, int attempt)
    {
        var observationWasDeadlockVictim =
            exception.Number == DeadlockVictimErrorNumber;
        var anotherAttemptIsAvailable = attempt < MaximumAttempts;
        return observationWasDeadlockVictim && anotherAttemptIsAvailable;
    }

    private static async ValueTask<StorageObservation> ReadOnceAsync(
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
