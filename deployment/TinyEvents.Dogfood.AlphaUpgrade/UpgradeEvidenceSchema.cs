using Microsoft.Data.SqlClient;

internal static class UpgradeEvidenceSchema
{
    public static async Task CreateAsync(UpgradeSettings settings)
    {
        const string sql = """
            CREATE TABLE dbo.UpgradeProbeEffects
            (
                Id BIGINT IDENTITY(1, 1) NOT NULL PRIMARY KEY,
                MessageState NVARCHAR(32) NOT NULL,
                RecordedAtUtc DATETIMEOFFSET NOT NULL
            );
            """;

        await using var connection = new SqlConnection(settings.ConnectionString);
        await connection.OpenAsync();
        await using var command = new SqlCommand(sql, connection);
        await command.ExecuteNonQueryAsync();
    }
}
