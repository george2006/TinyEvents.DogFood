namespace TinyEvents.Dogfood.AlphaUpgrade.Contracts;

public sealed record UpgradeProbeEvent(
    Guid OperationId,
    string State);
