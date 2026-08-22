using Microsoft.Data.SqlClient;
using TinyEvents;

namespace TinyEvents.Dogfood.Operations;

internal static class SqlServerDogfoodObservationReader
{
    private const int DeadlockVictimErrorNumber = 1205;
    private const int MaximumAttempts = 3;

    public static async ValueTask<ScenarioObservation> ReadAsync(
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

        throw new InvalidOperationException("The SQL Server observation retry loop ended unexpectedly.");
    }

    private static bool ShouldRetry(SqlException exception, int attempt)
    {
        var observationWasDeadlockVictim =
            exception.Number == DeadlockVictimErrorNumber;
        var anotherAttemptIsAvailable = attempt < MaximumAttempts;
        return observationWasDeadlockVictim && anotherAttemptIsAvailable;
    }

    private static async ValueTask<ScenarioObservation> ReadOnceAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT SYSDATETIMEOFFSET();

            SELECT COUNT(*) FROM dbo.DogfoodBusinessOperations;

            SELECT
                COUNT(*),
                COALESCE(SUM(CASE WHEN Status = @PendingStatus THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN Status = @ProcessingStatus THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN Status = @ProcessedStatus THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN Status = @FailedStatus THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(AttemptCount), 0),
                MIN(ClaimExpiresAtUtc),
                MIN(NextAttemptAtUtc),
                MAX(CASE WHEN Status = @FailedStatus THEN LastError END)
            FROM dbo.TinyOutbox;

            SELECT COUNT(*), COUNT(*) - COUNT(DISTINCT OperationId)
            FROM dbo.DogfoodEffects;

            SELECT COUNT(*), MAX(RecordedAtUtc)
            FROM dbo.DogfoodConsumerAttempts;

            SELECT ClaimedBy, COUNT(*) FROM dbo.TinyOutbox
            WHERE ClaimedBy IS NOT NULL
            GROUP BY ClaimedBy ORDER BY ClaimedBy;

            SELECT WorkerId, COUNT(*) FROM dbo.DogfoodEffects
            GROUP BY WorkerId ORDER BY WorkerId;

            SELECT WorkerId, COUNT(*) FROM dbo.DogfoodConsumerAttempts
            GROUP BY WorkerId ORDER BY WorkerId;

            SELECT CONVERT(NVARCHAR(16), ProcessId), COUNT(*)
            FROM dbo.DogfoodEffects
            GROUP BY ProcessId ORDER BY ProcessId;

            SELECT ScenarioId, COUNT(*) FROM dbo.DogfoodEffects
            GROUP BY ScenarioId ORDER BY ScenarioId;

            SELECT ScenarioId, COUNT(*) FROM dbo.DogfoodConsumerAttempts
            GROUP BY ScenarioId ORDER BY ScenarioId;
            """;

        await using var connection = new SqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        AddStatusParameters(command);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await DogfoodObservationResultReader.ReadAsync(
            reader,
            cancellationToken);
    }

    private static void AddStatusParameters(SqlCommand command)
    {
        command.Parameters.AddWithValue(
            "@PendingStatus",
            (int)TinyOutboxMessageStatus.Pending);
        command.Parameters.AddWithValue(
            "@ProcessingStatus",
            (int)TinyOutboxMessageStatus.Processing);
        command.Parameters.AddWithValue(
            "@ProcessedStatus",
            (int)TinyOutboxMessageStatus.Processed);
        command.Parameters.AddWithValue(
            "@FailedStatus",
            (int)TinyOutboxMessageStatus.Failed);
    }
}
