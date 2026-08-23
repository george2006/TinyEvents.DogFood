using TinyEvents;

namespace TinyEvents.Dogfood.Operations;

internal sealed class DogfoodCleanupBatchCommand(
    ITinyOutboxCleanupStore cleanupStore)
{
    public async ValueTask<CleanupBatchResult> ExecuteAsync(
        DateTimeOffset cutoffUtc,
        int batchSize,
        CancellationToken cancellationToken = default)
    {
        var startedAtUtc = DateTimeOffset.UtcNow;
        var deletedCount = await cleanupStore.DeleteProcessedBeforeAsync(
            cutoffUtc,
            batchSize,
            cancellationToken);
        var completedAtUtc = DateTimeOffset.UtcNow;

        return new CleanupBatchResult(
            Environment.ProcessId,
            startedAtUtc,
            completedAtUtc,
            batchSize,
            deletedCount);
    }
}
