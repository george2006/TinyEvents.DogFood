using Microsoft.Data.SqlClient;

namespace TinyEvents.Dogfood.Operations;

internal sealed class DogfoodConsumerAttemptRecorder(
    DogfoodSettings settings,
    WorkerIdentity worker)
{
    public async ValueTask<int> RecordAsync(
        Guid operationId,
        string scenarioId,
        CancellationToken cancellationToken)
    {
        const string sql = """
            INSERT INTO dbo.DogfoodConsumerAttempts
            (
                OperationId,
                ScenarioId,
                WorkerId,
                RecordedAtUtc
            )
            VALUES
            (
                @OperationId,
                @ScenarioId,
                @WorkerId,
                SYSDATETIMEOFFSET()
            );

            SELECT COUNT(*)
            FROM dbo.DogfoodConsumerAttempts
            WHERE OperationId = @OperationId;
            """;

        await using var connection = new SqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@OperationId", operationId);
        command.Parameters.AddWithValue("@ScenarioId", scenarioId);
        command.Parameters.AddWithValue("@WorkerId", worker.Value);
        return (int)(await command.ExecuteScalarAsync(cancellationToken))!;
    }
}
