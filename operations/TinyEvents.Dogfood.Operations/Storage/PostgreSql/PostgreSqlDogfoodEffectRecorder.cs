using Npgsql;

namespace TinyEvents.Dogfood.Operations;

internal sealed class PostgreSqlDogfoodEffectRecorder(
    DogfoodSettings settings,
    WorkerIdentity worker) : DogfoodEffectRecorder
{
    public override async ValueTask RecordAsync(
        Guid operationId,
        string scenarioId,
        CancellationToken cancellationToken)
    {
        const string sql = """
            INSERT INTO "DogfoodEffects"
            (
                "OperationId",
                "ScenarioId",
                "WorkerId",
                "ProcessId",
                "RecordedAtUtc"
            )
            VALUES
            (
                @OperationId,
                @ScenarioId,
                @WorkerId,
                @ProcessId,
                @RecordedAtUtc
            );
            """;

        await using var connection = new NpgsqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new NpgsqlCommand(sql, connection);
        command.Parameters.AddWithValue("OperationId", operationId);
        command.Parameters.AddWithValue("ScenarioId", scenarioId);
        command.Parameters.AddWithValue("WorkerId", worker.Value);
        command.Parameters.AddWithValue("ProcessId", Environment.ProcessId);
        command.Parameters.AddWithValue("RecordedAtUtc", DateTimeOffset.UtcNow);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
