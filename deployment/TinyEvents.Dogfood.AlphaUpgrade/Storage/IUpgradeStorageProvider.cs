using Microsoft.Extensions.DependencyInjection;

internal interface IUpgradeStorageProvider
{
    UpgradeSettings LoadSettings();

    void AddPublisherServices(
        IServiceCollection services,
        UpgradeSettings settings);

    void AddProcessorServices(
        IServiceCollection services,
        UpgradeSettings settings);

    ValueTask ResetAsync(
        UpgradeSettings settings,
        CancellationToken cancellationToken);

    ValueTask CreateEvidenceSchemaAsync(
        UpgradeSettings settings,
        CancellationToken cancellationToken);

    ValueTask<UpgradeStateObservation> ReadObservationAsync(
        UpgradeSettings settings,
        CancellationToken cancellationToken);
}
