using Npgsql;

internal sealed class PostgreSqlUpgradeTransaction : IUpgradeTransaction
{
    public PostgreSqlUpgradeTransaction(string connectionString)
    {
        Connection = new NpgsqlConnection(connectionString);
        Connection.Open();
        Transaction = Connection.BeginTransaction();
    }

    public NpgsqlConnection Connection { get; }

    public NpgsqlTransaction Transaction { get; }

    public Task CommitAsync()
    {
        return Transaction.CommitAsync();
    }

    public async ValueTask DisposeAsync()
    {
        await Transaction.DisposeAsync();
        await Connection.DisposeAsync();
    }
}
