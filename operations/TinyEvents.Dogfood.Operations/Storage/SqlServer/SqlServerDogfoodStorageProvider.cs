using System.Data.Common;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using TinyEvents.SqlServer.EntityFrameworkCore;

namespace TinyEvents.Dogfood.Operations;

internal sealed class SqlServerDogfoodStorageProvider : IDogfoodStorageProvider
{
    public DogfoodSettings LoadSettings()
    {
        return SqlServerDogfoodSettingsLoader.Load(this);
    }

    public void AddServices(
        IServiceCollection services,
        DogfoodSettings settings)
    {
        SqlServerDogfoodStorageRegistration.Add(
            services,
            settings.ConnectionString);
    }

    public void ConfigureModel(ModelBuilder modelBuilder)
    {
        modelBuilder.UseTinyEventsOutbox();
    }

    public DbConnection CreateConnection(string connectionString)
    {
        return new SqlConnection(connectionString);
    }

    public ValueTask ResetAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        return SqlServerDogfoodDatabaseReset.ExecuteAsync(
            settings,
            cancellationToken);
    }

    public ValueTask<ScenarioObservation> ReadObservationAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        return SqlServerDogfoodObservationReader.ReadAsync(
            settings,
            cancellationToken);
    }

    public ValueTask<MigrationObservation> ReadMigrationObservationAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        return SqlServerDogfoodMigrationObservationReader.ReadAsync(
            settings,
            cancellationToken);
    }

    public ValueTask<StorageObservation> ReadStorageObservationAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        return SqlServerDogfoodStorageObservationReader.ReadAsync(
            settings,
            cancellationToken);
    }
}
