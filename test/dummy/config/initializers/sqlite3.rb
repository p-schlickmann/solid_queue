module SqliteImmediateTransactions
  def begin_db_transaction
    log("begin immediate transaction", "TRANSACTION") do
      with_raw_connection(allow_retry: true, materialize_transactions: false) do |conn|
        conn.transaction(:immediate)
      end
    end
  end
end

ActiveSupport.on_load :active_record do
  if defined?(ActiveRecord::ConnectionAdapters::SQLite3Adapter)
    ActiveRecord::ConnectionAdapters::SQLite3Adapter.prepend SqliteImmediateTransactions
  end
end
