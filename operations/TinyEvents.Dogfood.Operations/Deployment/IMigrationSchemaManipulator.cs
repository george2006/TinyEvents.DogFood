namespace TinyEvents.Dogfood.Operations;

internal interface IMigrationSchemaManipulator
{
    ValueTask RemoveOutboxTableAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken);

    ValueTask ReplaceMigrationChecksumAsync(
        DogfoodSettings settings,
        string checksum,
        CancellationToken cancellationToken);
}
