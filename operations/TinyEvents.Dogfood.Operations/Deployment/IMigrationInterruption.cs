namespace TinyEvents.Dogfood.Operations;

internal interface IMigrationInterruption
{
    ValueTask InstallAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken);

    ValueTask<MigrationInterruptionObservation> ReadAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken);

    ValueTask RemoveAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken);
}
