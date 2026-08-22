namespace TinyEvents.Dogfood.Operations;

internal static class MigrationInterruptionSelector
{
    public static IMigrationInterruption Select(
        IDogfoodStorageProvider storageProvider)
    {
        return storageProvider switch
        {
            SqlServerDogfoodStorageProvider =>
                new SqlServerMigrationInterruption(),
            PostgreSqlDogfoodStorageProvider =>
                new PostgreSqlMigrationInterruption(),
            _ => throw new InvalidOperationException(
                $"Storage provider '{storageProvider.GetType().Name}' does not support migration interruption dogfood.")
        };
    }
}
