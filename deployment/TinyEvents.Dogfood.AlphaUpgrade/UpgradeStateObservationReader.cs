using Microsoft.Data.SqlClient;
using TinyEvents;

internal static class UpgradeStateObservationReader
{
    public static async Task<UpgradeStateObservation> ReadAsync(UpgradeSettings settings)
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
                MAX(CASE WHEN Status = @FailedStatus THEN LastError END) AS FailedLastError,
                COUNT(DISTINCT EventType) AS DistinctEventTypeCount,
                MIN(EventType) AS EventType,
                (SELECT COUNT(*) FROM dbo.TinyOutboxMigrations) AS MigrationCount,
                (SELECT COUNT(*) FROM dbo.UpgradeProbeEffects) AS EffectCount,
                (SELECT COUNT(DISTINCT MessageState) FROM dbo.UpgradeProbeEffects) AS DistinctEffectCount,
                (SELECT COUNT(*) FROM dbo.UpgradeProbeEffects WHERE MessageState = 'pending') AS PendingEffectCount,
                (SELECT COUNT(*) FROM dbo.UpgradeProbeEffects WHERE MessageState = 'processing') AS ProcessingEffectCount,
                (SELECT COUNT(*) FROM dbo.UpgradeProbeEffects WHERE MessageState = 'failed') AS FailedEffectCount
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

        return new UpgradeStateObservation(
            reader.GetInt32(0),
            reader.GetInt32(1),
            reader.GetInt32(2),
            reader.GetInt32(3),
            reader.GetInt32(4),
            reader.GetInt32(5),
            reader.GetInt32(6),
            reader.GetString(7),
            reader.GetInt32(8),
            reader.GetString(9),
            reader.GetInt32(10),
            reader.GetInt32(11),
            reader.GetInt32(12),
            reader.GetInt32(13),
            reader.GetInt32(14),
            reader.GetInt32(15));
    }
}

internal sealed record UpgradeStateObservation(
    int MessageCount,
    int PendingCount,
    int ProcessingCount,
    int ReclaimableProcessingCount,
    int ProcessedCount,
    int FailedCount,
    int FailedAttemptCount,
    string FailedLastError,
    int DistinctEventTypeCount,
    string EventType,
    int MigrationCount,
    int EffectCount,
    int DistinctEffectCount,
    int PendingEffectCount,
    int ProcessingEffectCount,
    int FailedEffectCount);
