using Microsoft.EntityFrameworkCore;
using TinyEvents;

namespace TinyEvents.Dogfood.Operations;

internal sealed class DogfoodCleanupBoundaryFixture(DogfoodDbContext dbContext)
{
    private static readonly DateTimeOffset CutoffUtc =
        new(2026, 8, 23, 12, 0, 0, TimeSpan.Zero);

    public async ValueTask<CleanupBoundary> PrepareAsync(
        CancellationToken cancellationToken)
    {
        var messages = await dbContext
            .Set<TinyOutboxMessage>()
            .OrderBy(message => message.CreatedAtUtc)
            .ThenBy(message => message.Id)
            .ToArrayAsync(cancellationToken);

        if (messages.Length != 6)
        {
            throw new InvalidOperationException(
                $"Cleanup boundary requires exactly six messages. Actual: {messages.Length}.");
        }

        MarkProcessed(messages[0], CutoffUtc.AddMinutes(-1));
        MarkProcessed(messages[1], CutoffUtc);
        MarkProcessed(messages[2], CutoffUtc.AddMinutes(1));
        LeavePending(messages[3]);
        MarkProcessing(messages[4]);
        MarkFailed(messages[5]);

        await dbContext.SaveChangesAsync(cancellationToken);

        return new CleanupBoundary(
            CutoffUtc,
            messages[0].Id,
            messages[1].Id,
            messages[2].Id,
            messages[3].Id,
            messages[4].Id,
            messages[5].Id);
    }

    public async ValueTask<CleanupBoundaryObservation> ObserveAsync(
        CleanupBoundary boundary,
        CancellationToken cancellationToken)
    {
        dbContext.ChangeTracker.Clear();

        var messages = await dbContext
            .Set<TinyOutboxMessage>()
            .AsNoTracking()
            .Where(message => boundary.MessageIds.Contains(message.Id))
            .ToDictionaryAsync(message => message.Id, cancellationToken);

        return new CleanupBoundaryObservation(
            ReadRow(boundary.EligibleProcessedId, messages),
            ReadRow(boundary.BoundaryProcessedId, messages),
            ReadRow(boundary.RecentProcessedId, messages),
            ReadRow(boundary.PendingId, messages),
            ReadRow(boundary.ProcessingId, messages),
            ReadRow(boundary.FailedId, messages));
    }

    private static CleanupBoundaryRow ReadRow(
        Guid id,
        IReadOnlyDictionary<Guid, TinyOutboxMessage> messages)
    {
        if (!messages.TryGetValue(id, out var message))
        {
            return new CleanupBoundaryRow(id, false, null, null);
        }

        return new CleanupBoundaryRow(
            id,
            true,
            message.Status.ToString(),
            message.ProcessedAtUtc);
    }

    private void MarkProcessed(
        TinyOutboxMessage message,
        DateTimeOffset processedAtUtc)
    {
        SetStatus(message, TinyOutboxMessageStatus.Processed);
        SetProcessedAtUtc(message, processedAtUtc);
        ClearClaim(message);
        ClearFailure(message);
    }

    private void LeavePending(TinyOutboxMessage message)
    {
        SetStatus(message, TinyOutboxMessageStatus.Pending);
        SetProcessedAtUtc(message, null);
        ClearClaim(message);
        ClearFailure(message);
    }

    private void MarkProcessing(TinyOutboxMessage message)
    {
        SetStatus(message, TinyOutboxMessageStatus.Processing);
        SetProcessedAtUtc(message, null);
        SetProperty(message, candidate => candidate.ClaimedBy, "TE-L06-A-fixture");
        SetProperty(message, candidate => candidate.ClaimedAtUtc, CutoffUtc);
        SetProperty(
            message,
            candidate => candidate.ClaimExpiresAtUtc,
            CutoffUtc.AddMinutes(5));
        ClearFailure(message);
    }

    private void MarkFailed(TinyOutboxMessage message)
    {
        SetStatus(message, TinyOutboxMessageStatus.Failed);
        SetProcessedAtUtc(message, null);
        ClearClaim(message);
        SetProperty(message, candidate => candidate.AttemptCount, 3);
        SetProperty(message, candidate => candidate.NextAttemptAtUtc, null);
        SetProperty(
            message,
            candidate => candidate.LastError,
            "TE-L06-A terminal failure");
    }

    private void ClearClaim(TinyOutboxMessage message)
    {
        SetProperty(message, candidate => candidate.ClaimedBy, null);
        SetProperty(message, candidate => candidate.ClaimedAtUtc, null);
        SetProperty(message, candidate => candidate.ClaimExpiresAtUtc, null);
    }

    private void ClearFailure(TinyOutboxMessage message)
    {
        SetProperty(message, candidate => candidate.AttemptCount, 0);
        SetProperty(message, candidate => candidate.NextAttemptAtUtc, null);
        SetProperty(message, candidate => candidate.LastError, null);
    }

    private void SetStatus(
        TinyOutboxMessage message,
        TinyOutboxMessageStatus status)
    {
        SetProperty(message, candidate => candidate.Status, status);
    }

    private void SetProcessedAtUtc(
        TinyOutboxMessage message,
        DateTimeOffset? processedAtUtc)
    {
        SetProperty(
            message,
            candidate => candidate.ProcessedAtUtc,
            processedAtUtc);
    }

    private void SetProperty<TValue>(
        TinyOutboxMessage message,
        System.Linq.Expressions.Expression<Func<TinyOutboxMessage, TValue>> property,
        TValue value)
    {
        dbContext.Entry(message).Property(property).CurrentValue = value;
    }
}
