using TinyEvents;

namespace TinyEvents.Dogfood.Operations;

internal sealed class DogfoodCleanupBoundaryScenario(
    DogfoodPublisher publisher,
    DogfoodCleanupBoundaryFixture fixture,
    ITinyOutboxCleanupStore cleanupStore)
{
    private const int BoundaryMessageCount = 6;
    private const int CleanupBatchSize = 100;

    public async ValueTask<CleanupBoundaryResult> ExecuteAsync(
        CancellationToken cancellationToken = default)
    {
        await publisher.PublishAsync(
            "TE-L06-A",
            BoundaryMessageCount,
            cancellationToken);

        var boundary = await fixture.PrepareAsync(cancellationToken);
        var deletedCount = await cleanupStore.DeleteProcessedBeforeAsync(
            boundary.CutoffUtc,
            CleanupBatchSize,
            cancellationToken);
        var observation = await fixture.ObserveAsync(
            boundary,
            cancellationToken);

        return new CleanupBoundaryResult(
            boundary.CutoffUtc,
            deletedCount,
            observation);
    }
}
