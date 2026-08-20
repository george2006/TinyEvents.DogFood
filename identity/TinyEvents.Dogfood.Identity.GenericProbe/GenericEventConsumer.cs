namespace TinyEvents.Dogfood.Identity.GenericProbe;

public sealed record GenericEvent<T>(T Value);

public sealed class GenericEventConsumer : IEventConsumer<GenericEvent<int>>
{
    public ValueTask ConsumeAsync(
        GenericEvent<int> @event,
        CancellationToken cancellationToken)
    {
        return ValueTask.CompletedTask;
    }
}
