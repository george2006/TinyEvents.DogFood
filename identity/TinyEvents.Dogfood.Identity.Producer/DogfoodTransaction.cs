using Microsoft.Data.SqlClient;

internal sealed class DogfoodTransaction : IAsyncDisposable
{
    public DogfoodTransaction(string connectionString)
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
