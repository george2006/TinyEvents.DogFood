using Microsoft.Data.SqlClient;
using TinyEvents;

internal static class AlphaStateObservationReader
{
    public static async Task<AlphaStateObservation> ReadAsync(UpgradeSettings settings)
    {
        const string sql = """
            SELECT
                COUNT(*) AS MessageCount,
                SUM(CASE WHEN Status = @PendingStatus THEN 1 ELSE 0 END) AS PendingCount,
                SUM(CASE WHEN Status = @ProcessingStatus THEN 1 ELSE 0 END) AS ProcessingCount,
                SUM(CASE WHEN Status = @ProcessingStatus AND ClaimExpiresAtUtc <= SYSUTCDATETIME() THEN 1 ELSE 0 END) AS ReclaimableProcessingCount,
                SUM(CASE WHEN Status = @ProcessedStatus THEN 1 ELSE 0 END) AS ProcessedCount,
                SUM(CASE WHEN Status = @FailedStatus THEN 1 ELSE 0 END) AS FailedCount,
                SUM(CASE WHEN Status = @FailedStatus THEN AttemptCount ELSE 0 END) AS FailedAttemptCount,
                COUNT(DISTINCT EventType) AS DistinctEventTypeCount,
                MIN(EventType) AS EventType,
                (SELECT COUNT(*) FROM dbo.TinyOutboxMigrations) AS MigrationCount,
                (SELECT COUNT(*) FROM dbo.UpgradeProbeEffects) AS EffectCount
            FROM dbo.TinyOutbox;
            """;

        await using var connection = new SqlConnection(settings.ConnectionString);
        await connection.OpenAsync();
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@PendingStatus", (int)TinyOutboxMessageStatus.Pending);
        command.Parameters.AddWithValue("@ProcessingStatus", (int)TinyOutboxMessageStatus.Processing);
        command.Parameters.AddWithValue("@ProcessedStatus", (int)TinyOutboxMessageStatus.Processed);
        command.Parameters.AddWithValue("@FailedStatus", (int)TinyOutboxMessageStatus.Failed);
        await using var reader = await command.ExecuteReaderAsync();
        await reader.ReadAsync();

        return new AlphaStateObservation(
            reader.GetInt32(0),
            reader.GetInt32(1),
            reader.GetInt32(2),
            reader.GetInt32(3),
            reader.GetInt32(4),
            reader.GetInt32(5),
            reader.GetInt32(6),
            reader.GetInt32(7),
            reader.GetString(8),
            reader.GetInt32(9),
            reader.GetInt32(10));
    }
}

internal sealed record AlphaStateObservation(
    int MessageCount,
    int PendingCount,
    int ProcessingCount,
    int ReclaimableProcessingCount,
    int ProcessedCount,
    int FailedCount,
    int FailedAttemptCount,
    int DistinctEventTypeCount,
    string EventType,
    int MigrationCount,
    int EffectCount);
