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
                new OperationalEvent(operationId, scenarioId),
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
}
