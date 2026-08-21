using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using TinyEvents.SqlServer.EntityFrameworkCore;

namespace TinyEvents.Dogfood.Operations;

internal static class SqlServerDogfoodStorageRegistration
{
    public static void Add(
        IServiceCollection services,
        string connectionString)
    {
        services.AddDbContext<DogfoodDbContext>(options =>
        {
            options.UseSqlServer(connectionString);
        });
        services.UseSqlServerEntityFrameworkCoreOutbox<DogfoodDbContext>();
    }
}
