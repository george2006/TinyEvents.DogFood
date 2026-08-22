using Microsoft.EntityFrameworkCore;
using TinyEvents;

namespace TinyEvents.Dogfood.Operations;

internal sealed class DogfoodPublisher(
    DogfoodDbContext dbContext,
    ITinyEventPublisher publisher)
{
    public async ValueTask PublishAsync(
        string scenarioId,
        int count,
        CancellationToken cancellationToken = default)
    {
        await PublishAsync(
            scenarioId,
            count,
            content: string.Empty,
            cancellationToken);
    }

    public async ValueTask PublishWithContentAsync(
        string scenarioId,
        int count,
        int contentCharacterCount,
        CancellationToken cancellationToken = default)
    {
        var content = new string('x', contentCharacterCount);
        await PublishAsync(
            scenarioId,
            count,
            content,
            cancellationToken);
    }

    private async ValueTask PublishAsync(
        string scenarioId,
        int count,
        string content,
        CancellationToken cancellationToken)
    {
        for (var index = 0; index < count; index++)
        {
            var operationId = Guid.NewGuid();

            dbContext.BusinessOperations.Add(new DogfoodBusinessOperation
            {
                Id = operationId,
                ScenarioId = scenarioId,
                CreatedAtUtc = DateTimeOffset.UtcNow
            });

            await publisher.PublishAsync(
                new OperationalEvent(operationId, scenarioId, content),
                cancellationToken);
        }

        await dbContext.SaveChangesAsync(cancellationToken);
    }

    public async ValueTask PublishMultiConsumerAsync(
        string scenarioId,
        int count,
        CancellationToken cancellationToken = default)
    {
        for (var index = 0; index < count; index++)
        {
            var operationId = Guid.NewGuid();

            dbContext.BusinessOperations.Add(new DogfoodBusinessOperation
            {
                Id = operationId,
                ScenarioId = scenarioId,
                CreatedAtUtc = DateTimeOffset.UtcNow
            });

            await publisher.PublishAsync(
                new MultiConsumerOperationalEvent(operationId, scenarioId),
                cancellationToken);
        }

        await dbContext.SaveChangesAsync(cancellationToken);
    }

    public async ValueTask PublishThenRollbackAsync(
        string scenarioId,
        int count,
        CancellationToken cancellationToken = default)
    {
        await using var transaction =
            await dbContext.Database.BeginTransactionAsync(cancellationToken);

        await PublishAsync(scenarioId, count, cancellationToken);
        await transaction.RollbackAsync(cancellationToken);
    }
}
