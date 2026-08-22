namespace TinyEvents.Dogfood.Operations;

internal sealed record MigrationInterruptionObservation(
    bool IsInstalled,
    int BlockedMigratorCount,
    int BlockedMigratorsHoldingLock,
    int MigrationLockHolderCount);
