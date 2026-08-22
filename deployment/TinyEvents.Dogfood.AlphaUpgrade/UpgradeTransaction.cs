using Microsoft.Data.SqlClient;

internal sealed class UpgradeTransaction : IAsyncDisposable
{
    public UpgradeTransaction(string connectionString)
    {
        Connection = new SqlConnection(connectionString);
        Connection.Open();
        Transaction = Connection.BeginTransaction();
    }

    public SqlConnection Connection { get; }

    public SqlTransaction Transaction { get; }

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
