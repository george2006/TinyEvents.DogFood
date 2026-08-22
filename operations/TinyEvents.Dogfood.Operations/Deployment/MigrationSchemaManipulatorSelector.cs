namespace TinyEvents.Dogfood.Operations;

internal static class MigrationSchemaManipulatorSelector
{
    public static IMigrationSchemaManipulator Select(
        IDogfoodStorageProvider storageProvider)
    {
        return storageProvider switch
        {
            SqlServerDogfoodStorageProvider =>
                new SqlServerMigrationSchemaManipulator(),
            PostgreSqlDogfoodStorageProvider =>
                new PostgreSqlMigrationSchemaManipulator(),
            _ => throw new InvalidOperationException(
                $"Storage provider '{storageProvider.GetType().Name}' does not support migration schema manipulation.")
        };
    }
}
