using Microsoft.EntityFrameworkCore;
using PostgreSqlModel = TinyEvents.PostgreSql.EntityFrameworkCore.TinyEventsModelBuilderExtensions;
using SqlServerModel = TinyEvents.SqlServer.EntityFrameworkCore.TinyEventsModelBuilderExtensions;

namespace TinyEvents.Dogfood.Operations;

internal sealed class DogfoodDbContext : DbContext
{
    private readonly DogfoodSettings settings;

    public DogfoodDbContext(
        DbContextOptions<DogfoodDbContext> options,
        DogfoodSettings settings)
        : base(options)
    {
        this.settings = settings;
    }

    public DbSet<DogfoodBusinessOperation> BusinessOperations =>
        Set<DogfoodBusinessOperation>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<DogfoodBusinessOperation>(entity =>
        {
            entity.ToTable("DogfoodBusinessOperations");
            entity.HasKey(operation => operation.Id);
            entity.Property(operation => operation.ScenarioId).IsRequired().HasMaxLength(32);
        });

        switch (settings.StorageProvider)
        {
            case DogfoodStorageProvider.SqlServer:
                SqlServerModel.UseTinyEventsOutbox(modelBuilder);
                return;

            case DogfoodStorageProvider.PostgreSql:
                PostgreSqlModel.UseTinyEventsOutbox(modelBuilder);
                return;

            default:
                throw new ArgumentOutOfRangeException(
                    nameof(settings),
                    settings.StorageProvider,
                    "Unknown dogfood storage provider.");
        }
    }
}

internal sealed class DogfoodBusinessOperation
{
    public Guid Id { get; set; }

    public string ScenarioId { get; set; } = string.Empty;

    public DateTimeOffset CreatedAtUtc { get; set; }
}
