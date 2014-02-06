require_relative 'live_query'
require 'utils/generic_pool'

class LiveQueryPool < GenericPool
  def initialize(data_store)
    super
    @data_store = data_store
  end
  
  def lookup(collection, query)
    query = normalize_query(query)
    
    return super(collection, query)
  end
  
  def updated_collection(collection, skip_channel)
    if @pool[collection]
      @pool[collection].each_pair do |query,live_query|
        live_query.run(skip_channel)
      end
    end
  end
  
  private
    # Creates the live query if it doesn't exist, and stores it so it
    # can be found later.
    def create(collection, query)
      # If not already setup, create a new one for this collection/query
      return LiveQuery.new(self, @data_store, collection, query)
    end
  
    def normalize_query(query)
      # TODO: add something to sort query properties so the queries are
      # always compared the same.
      return query
    end
end