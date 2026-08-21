using Microsoft.Data.SqlClient;

namespace TinyEvents.Dogfood.Operations;

internal sealed class SqlServerDogfoodEffectRecorder(
    DogfoodSettings settings,
    WorkerIdentity worker) : DogfoodEffectRecorder
{
    public override async ValueTask RecordAsync(
        Guid operationId,
        string scenarioId,
        CancellationToken cancellationToken)
    {
        const string sql = """
            INSERT INTO dbo.DogfoodEffects
            (
                OperationId,
                ScenarioId,
                WorkerId,
                ProcessId,
                RecordedAtUtc
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

        await using var connection = new SqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@OperationId", operationId);
        command.Parameters.AddWithValue("@ScenarioId", scenarioId);
        command.Parameters.AddWithValue("@WorkerId", worker.Value);
        command.Parameters.AddWithValue("@ProcessId", Environment.ProcessId);
        command.Parameters.AddWithValue("@RecordedAtUtc", DateTimeOffset.UtcNow);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
