using Microsoft.EntityFrameworkCore;
using TinyEvents;

namespace TinyEvents.Dogfood.Operations;

internal sealed class DogfoodCleanupPopulationFixture(
    DogfoodPublisher publisher,
    DogfoodDbContext dbContext)
{
    private const string ScenarioId = "TE-L06-B";

    public async ValueTask<CleanupPopulationResult> PrepareAsync(
        int messageCount,
        DateTimeOffset cutoffUtc,
        CancellationToken cancellationToken = default)
    {
        await publisher.PublishAsync(
            ScenarioId,
            messageCount,
            cancellationToken);

        var messages = await dbContext
            .Set<TinyOutboxMessage>()
            .ToArrayAsync(cancellationToken);

        if (messages.Length != messageCount)
        {
            throw new InvalidOperationException(
                $"Cleanup population requires {messageCount} messages. Actual: {messages.Length}.");
        }

        foreach (var message in messages)
        {
            MarkEligibleForCleanup(message, cutoffUtc);
        }

        await dbContext.SaveChangesAsync(cancellationToken);
        return new CleanupPopulationResult(cutoffUtc, messages.Length);
    }

    private void MarkEligibleForCleanup(
        TinyOutboxMessage message,
        DateTimeOffset cutoffUtc)
    {
        SetProperty(
            message,
            candidate => candidate.Status,
            TinyOutboxMessageStatus.Processed);
        SetProperty(
            message,
            candidate => candidate.ProcessedAtUtc,
            cutoffUtc.AddMinutes(-1));
        SetProperty(message, candidate => candidate.ClaimedBy, null);
        SetProperty(message, candidate => candidate.ClaimedAtUtc, null);
        SetProperty(message, candidate => candidate.ClaimExpiresAtUtc, null);
        SetProperty(message, candidate => candidate.AttemptCount, 0);
        SetProperty(message, candidate => candidate.NextAttemptAtUtc, null);
        SetProperty(message, candidate => candidate.LastError, null);
    }

    private void SetProperty<TValue>(
        TinyOutboxMessage message,
        System.Linq.Expressions.Expression<Func<TinyOutboxMessage, TValue>> property,
        TValue value)
    {
        dbContext.Entry(message).Property(property).CurrentValue = value;
    }
}
