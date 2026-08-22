using Microsoft.Data.SqlClient;

internal static class SqlServerUpgradeEvidenceSchema
{
    public static async ValueTask CreateAsync(
        UpgradeSettings settings,
        CancellationToken cancellationToken)
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
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
