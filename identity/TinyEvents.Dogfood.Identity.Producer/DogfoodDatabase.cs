using Microsoft.Data.SqlClient;

internal static class DogfoodDatabase
{
    public static async Task ResetAsync(DogfoodSettings settings)
    {
        await using var connection = new SqlConnection(settings.MasterConnectionString);
        await connection.OpenAsync();

        var quotedDatabaseName = new SqlCommandBuilder().QuoteIdentifier(settings.DatabaseName);
        var sql = $"""
            IF DB_ID(@DatabaseName) IS NOT NULL
            BEGIN
                ALTER DATABASE {quotedDatabaseName} SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
                DROP DATABASE {quotedDatabaseName};
            END;

            CREATE DATABASE {quotedDatabaseName};
            """;

        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@DatabaseName", settings.DatabaseName);
        await command.ExecuteNonQueryAsync();
    }

    public static async Task CreateEvidenceTableAsync(DogfoodSettings settings)
    {
        const string sql = """
            CREATE TABLE dbo.DogfoodEffects
            (
                Id BIGINT IDENTITY(1, 1) NOT NULL PRIMARY KEY,
                ScenarioId NVARCHAR(32) NOT NULL,
                ConsumerName NVARCHAR(256) NOT NULL,
                RecordedAtUtc DATETIMEOFFSET NOT NULL
            );
            """;

        await using var connection = new SqlConnection(settings.ConnectionString);
        await connection.OpenAsync();
        await using var command = new SqlCommand(sql, connection);
        await command.ExecuteNonQueryAsync();
    }
}
