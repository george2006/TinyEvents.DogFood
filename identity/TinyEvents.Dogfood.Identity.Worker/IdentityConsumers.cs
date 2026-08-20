using TinyEvents.Dogfood.Identity.Contracts;
using TinyEvents.Dogfood.Identity.Moved;
using TinyEvents.Dogfood.Identity.Nested;
using TinyEvents.Dogfood.Identity.Rename.V2;

namespace TinyEvents.Dogfood.Identity.Worker;

public sealed class NormalEventConsumer(DogfoodEffectRecorder effects) : IEventConsumer<NormalEvent>
{
    public ValueTask ConsumeAsync(NormalEvent @event, CancellationToken cancellationToken)
    {
        return effects.RecordAsync(@event.ScenarioId, nameof(NormalEventConsumer), cancellationToken);
    }
}

public sealed class NestedEventConsumer(DogfoodEffectRecorder effects) : IEventConsumer<EventContainer.NestedEvent>
{
    public ValueTask ConsumeAsync(EventContainer.NestedEvent @event, CancellationToken cancellationToken)
    {
        return effects.RecordAsync(@event.ScenarioId, nameof(NestedEventConsumer), cancellationToken);
    }
}

public sealed class RenamedEventConsumer(DogfoodEffectRecorder effects) : IEventConsumer<RenamedEvent>
{
    public ValueTask ConsumeAsync(RenamedEvent @event, CancellationToken cancellationToken)
    {
        return effects.RecordAsync(@event.ScenarioId, nameof(RenamedEventConsumer), cancellationToken);
    }
}

public sealed class MovedEventConsumer(DogfoodEffectRecorder effects) : IEventConsumer<MovedEvent>
{
    public ValueTask ConsumeAsync(MovedEvent @event, CancellationToken cancellationToken)
    {
        return effects.RecordAsync(@event.ScenarioId, nameof(MovedEventConsumer), cancellationToken);
    }
}
