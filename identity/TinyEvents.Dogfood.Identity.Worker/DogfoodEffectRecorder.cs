using Microsoft.Data.SqlClient;

namespace TinyEvents.Dogfood.Identity.Worker;

public sealed class DogfoodEffectRecorder(string connectionString)
{
    public async ValueTask RecordAsync(
        string scenarioId,
        string consumerName,
        CancellationToken cancellationToken)
    {
        const string sql = """
            INSERT INTO dbo.DogfoodEffects
            (
                ScenarioId,
                ConsumerName,
                RecordedAtUtc
            )
            VALUES
            (
                @ScenarioId,
                @ConsumerName,
                SYSUTCDATETIME()
            );
            """;

        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@ScenarioId", scenarioId);
        command.Parameters.AddWithValue("@ConsumerName", consumerName);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
