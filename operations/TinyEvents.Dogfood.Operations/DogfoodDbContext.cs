using Microsoft.EntityFrameworkCore;
using TinyEvents.SqlServer.EntityFrameworkCore;

namespace TinyEvents.Dogfood.Operations;

internal sealed class DogfoodDbContext : DbContext
{
    public DogfoodDbContext(DbContextOptions<DogfoodDbContext> options)
        : base(options)
    {
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

        modelBuilder.UseTinyEventsOutbox();
    }
}

internal sealed class DogfoodBusinessOperation
{
    public Guid Id { get; set; }

    public string ScenarioId { get; set; } = string.Empty;

    public DateTimeOffset CreatedAtUtc { get; set; }
}
