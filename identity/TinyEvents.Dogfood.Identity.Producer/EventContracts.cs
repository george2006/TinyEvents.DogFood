namespace TinyEvents.Dogfood.Identity.Nested
{
    public static class EventContainer
    {
        public sealed record NestedEvent(string ScenarioId);
    }
}

namespace TinyEvents.Dogfood.Identity.Rename.V1
{
    public sealed record RenamedEvent(string ScenarioId);
}

namespace TinyEvents.Dogfood.Identity.Moved
{
    public sealed record MovedEvent(string ScenarioId);
}

namespace TinyEvents.Dogfood.Identity.Additive
{
    public sealed record AdditiveEvent(string ScenarioId);
}
