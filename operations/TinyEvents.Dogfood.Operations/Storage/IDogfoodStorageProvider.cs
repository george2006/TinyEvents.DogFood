using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace TinyEvents.Dogfood.Operations;

internal interface IDogfoodStorageProvider
{
    DogfoodSettings LoadSettings();

    void AddServices(
        IServiceCollection services,
        DogfoodSettings settings);

    void ConfigureModel(ModelBuilder modelBuilder);

    ValueTask ResetAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken);

    ValueTask<ScenarioObservation> ReadObservationAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken);

    ValueTask<MigrationObservation> ReadMigrationObservationAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken);
}
