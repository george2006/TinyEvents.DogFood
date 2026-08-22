using Npgsql;
using TinyEvents;

internal static class PostgreSqlUpgradeStateObservationReader
{
    public static async ValueTask<UpgradeStateObservation> ReadAsync(
        UpgradeSettings settings,
        CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT
                COUNT(*)::integer,
                COALESCE(SUM(CASE WHEN "Status" = @PendingStatus THEN 1 ELSE 0 END), 0)::integer,
                COALESCE(SUM(CASE WHEN "Status" = @ProcessingStatus THEN 1 ELSE 0 END), 0)::integer,
                COALESCE(SUM(CASE WHEN "Status" = @ProcessingStatus AND "ClaimExpiresAtUtc" <= CURRENT_TIMESTAMP THEN 1 ELSE 0 END), 0)::integer,
                COALESCE(SUM(CASE WHEN "Status" = @ProcessedStatus THEN 1 ELSE 0 END), 0)::integer,
                COALESCE(SUM(CASE WHEN "Status" = @FailedStatus THEN 1 ELSE 0 END), 0)::integer,
                COALESCE(SUM(CASE WHEN "Status" = @FailedStatus THEN "AttemptCount" ELSE 0 END), 0)::integer,
                MAX(CASE WHEN "Status" = @FailedStatus THEN "LastError" END),
                COUNT(DISTINCT "EventType")::integer,
                MIN("EventType"),
                (SELECT COUNT(*)::integer FROM "TinyOutboxMigrations"),
                (SELECT COUNT(*)::integer FROM "UpgradeProbeEffects"),
                (SELECT COUNT(DISTINCT "MessageState")::integer FROM "UpgradeProbeEffects"),
                (SELECT COUNT(*)::integer FROM "UpgradeProbeEffects" WHERE "MessageState" = 'pending'),
                (SELECT COUNT(*)::integer FROM "UpgradeProbeEffects" WHERE "MessageState" = 'processing'),
                (SELECT COUNT(*)::integer FROM "UpgradeProbeEffects" WHERE "MessageState" = 'failed'),
                (SELECT COUNT(DISTINCT "OperationId")::integer FROM "UpgradeProbeEffects"),
                (SELECT COUNT(DISTINCT "WorkerId")::integer FROM "UpgradeProbeEffects")
            FROM "TinyOutbox";
            """;

        await using var connection = new NpgsqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new NpgsqlCommand(sql, connection);
        command.Parameters.AddWithValue(
            "PendingStatus",
            (int)TinyOutboxMessageStatus.Pending);
        command.Parameters.AddWithValue(
            "ProcessingStatus",
            (int)TinyOutboxMessageStatus.Processing);
        command.Parameters.AddWithValue(
            "ProcessedStatus",
            (int)TinyOutboxMessageStatus.Processed);
        command.Parameters.AddWithValue(
            "FailedStatus",
            (int)TinyOutboxMessageStatus.Failed);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        await reader.ReadAsync(cancellationToken);

        return UpgradeStateObservationResultReader.Read(reader);
    }
}
