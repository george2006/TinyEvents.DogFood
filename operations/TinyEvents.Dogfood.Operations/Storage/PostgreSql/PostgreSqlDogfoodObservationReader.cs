using Npgsql;
using TinyEvents;

namespace TinyEvents.Dogfood.Operations;

internal static class PostgreSqlDogfoodObservationReader
{
    public static async ValueTask<ScenarioObservation> ReadAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT CURRENT_TIMESTAMP;

            SELECT COUNT(*) FROM "DogfoodBusinessOperations";

            SELECT
                COUNT(*),
                COALESCE(SUM(CASE WHEN "Status" = @PendingStatus THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN "Status" = @ProcessingStatus THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN "Status" = @ProcessedStatus THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN "Status" = @FailedStatus THEN 1 ELSE 0 END), 0),
                COALESCE(SUM("AttemptCount"), 0),
                MIN("ClaimExpiresAtUtc"),
                MIN("NextAttemptAtUtc"),
                MAX(CASE WHEN "Status" = @FailedStatus THEN "LastError" END)
            FROM "TinyOutbox";

            SELECT COUNT(*), COUNT(*) - COUNT(DISTINCT "OperationId")
            FROM "DogfoodEffects";

            SELECT COUNT(*), MAX("RecordedAtUtc")
            FROM "DogfoodConsumerAttempts";

            SELECT "ClaimedBy", COUNT(*) FROM "TinyOutbox"
            WHERE "ClaimedBy" IS NOT NULL
            GROUP BY "ClaimedBy" ORDER BY "ClaimedBy";

            SELECT "WorkerId", COUNT(*) FROM "DogfoodEffects"
            GROUP BY "WorkerId" ORDER BY "WorkerId";

            SELECT "WorkerId", COUNT(*) FROM "DogfoodConsumerAttempts"
            GROUP BY "WorkerId" ORDER BY "WorkerId";

            SELECT CAST("ProcessId" AS character varying), COUNT(*)
            FROM "DogfoodEffects"
            GROUP BY "ProcessId" ORDER BY "ProcessId";

            SELECT "ScenarioId", COUNT(*) FROM "DogfoodEffects"
            GROUP BY "ScenarioId" ORDER BY "ScenarioId";

            SELECT "ScenarioId", COUNT(*) FROM "DogfoodConsumerAttempts"
            GROUP BY "ScenarioId" ORDER BY "ScenarioId";
            """;

        await using var connection = new NpgsqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new NpgsqlCommand(sql, connection);
        AddStatusParameters(command);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await DogfoodObservationResultReader.ReadAsync(
            reader,
            cancellationToken);
    }

    private static void AddStatusParameters(NpgsqlCommand command)
    {
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
    }
}
