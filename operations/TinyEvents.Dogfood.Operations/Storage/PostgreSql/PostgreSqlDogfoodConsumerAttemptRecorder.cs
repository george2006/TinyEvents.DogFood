using Npgsql;

namespace TinyEvents.Dogfood.Operations;

internal sealed class PostgreSqlDogfoodConsumerAttemptRecorder(
    DogfoodSettings settings,
    WorkerIdentity worker) : DogfoodConsumerAttemptRecorder
{
    public override async ValueTask<int> RecordAsync(
        Guid operationId,
        string scenarioId,
        CancellationToken cancellationToken)
    {
        const string sql = """
            INSERT INTO "DogfoodConsumerAttempts"
            (
                "OperationId",
                "ScenarioId",
                "WorkerId",
                "RecordedAtUtc"
            )
            VALUES
            (
                @OperationId,
                @ScenarioId,
                @WorkerId,
                CURRENT_TIMESTAMP
            );

            SELECT COUNT(*)
            FROM "DogfoodConsumerAttempts"
            WHERE "OperationId" = @OperationId;
            """;

        await using var connection = new NpgsqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new NpgsqlCommand(sql, connection);
        command.Parameters.AddWithValue("OperationId", operationId);
        command.Parameters.AddWithValue("ScenarioId", scenarioId);
        command.Parameters.AddWithValue("WorkerId", worker.Value);
        return Convert.ToInt32(
            await command.ExecuteScalarAsync(cancellationToken));
    }
}
