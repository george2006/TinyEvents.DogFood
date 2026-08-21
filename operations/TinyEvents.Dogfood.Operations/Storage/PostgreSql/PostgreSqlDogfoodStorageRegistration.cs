using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using TinyEvents.PostgreSql.EntityFrameworkCore;

namespace TinyEvents.Dogfood.Operations;

internal static class PostgreSqlDogfoodStorageRegistration
{
    public static void Add(
        IServiceCollection services,
        string connectionString)
    {
        services.AddSingleton<
            DogfoodConsumerAttemptRecorder,
            PostgreSqlDogfoodConsumerAttemptRecorder>();
        services.AddSingleton<
            DogfoodEffectRecorder,
            PostgreSqlDogfoodEffectRecorder>();
        services.AddDbContext<DogfoodDbContext>(options =>
        {
            options.UseNpgsql(connectionString);
        });
        services.UsePostgreSqlEntityFrameworkCoreOutbox<DogfoodDbContext>();
    }
}
