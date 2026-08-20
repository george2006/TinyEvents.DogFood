namespace TinyEvents.Dogfood.Identity.Worker;

internal static class DogfoodSettings
{
    private const string ConnectionStringVariable = "TINYEVENTS_DOGFOOD_SQLSERVER";

    public static string GetConnectionString()
    {
        var connectionString = Environment.GetEnvironmentVariable(ConnectionStringVariable);

        if (string.IsNullOrWhiteSpace(connectionString))
        {
            throw new InvalidOperationException($"Environment variable {ConnectionStringVariable} is required.");
        }

        return connectionString;
    }
}
