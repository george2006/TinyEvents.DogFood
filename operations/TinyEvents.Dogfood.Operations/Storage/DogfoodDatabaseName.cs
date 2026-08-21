namespace TinyEvents.Dogfood.Operations;

internal static class DogfoodDatabaseName
{
    private const string Prefix = "TinyEventsDogfood";

    public static string RequireValid(string? databaseName)
    {
        if (string.IsNullOrWhiteSpace(databaseName))
        {
            throw InvalidDatabaseName(databaseName);
        }

        var hasRequiredPrefix =
            databaseName.StartsWith(Prefix, StringComparison.Ordinal);
        var containsOnlySafeCharacters = databaseName.All(character =>
            char.IsLetterOrDigit(character) || character == '_');

        if (!hasRequiredPrefix || !containsOnlySafeCharacters)
        {
            throw InvalidDatabaseName(databaseName);
        }

        return databaseName;
    }

    private static InvalidOperationException InvalidDatabaseName(
        string? databaseName)
    {
        return new InvalidOperationException(
            $"Dogfood database name must start with '{Prefix}' and contain only letters, numbers, or underscores. Actual: '{databaseName}'.");
    }
}
