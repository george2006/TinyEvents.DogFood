namespace TinyEvents.Dogfood.Operations;

internal sealed record StorageObservation(
    long RowCount,
    long PayloadBytes,
    long TableAllocatedBytes,
    long IndexAllocatedBytes,
    long TotalAllocatedBytes);
