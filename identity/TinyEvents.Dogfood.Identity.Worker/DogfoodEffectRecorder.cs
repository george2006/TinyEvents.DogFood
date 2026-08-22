using Microsoft.Data.SqlClient;

namespace TinyEvents.Dogfood.Identity.Worker;

public sealed class DogfoodEffectRecorder(string connectionString)
{
    public async ValueTask RecordAsync(
        string scenarioId,
        string consumerName,
        CancellationToken cancellationToken,
        string? observedValue = null)
    {
        const string sql = """
            INSERT INTO dbo.DogfoodEffects
            (
                ScenarioId,
                ConsumerName,
                ObservedValue,
                RecordedAtUtc
            )
            VALUES
            (
                @ScenarioId,
                @ConsumerName,
                @ObservedValue,
                SYSUTCDATETIME()
            );
            """;

        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@ScenarioId", scenarioId);
        command.Parameters.AddWithValue("@ConsumerName", consumerName);
        command.Parameters.AddWithValue("@ObservedValue", (object?)observedValue ?? DBNull.Value);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
