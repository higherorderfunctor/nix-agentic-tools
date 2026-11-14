# Select family-based helper pools for routing views and session-pool option types.
# Module and manual builders pass their registry; collection registrations stay separate.
{lib}: pools:
lib.filterAttrs (_: pool: pool.limits == {} && (pool.usage == null || pool.usage.readerPool == null))
(lib.mapAttrs (_: pool:
    {
      description = "";
      limits = {};
      usage = null;
      window = null;
    }
    // pool
    // lib.optionalAttrs (pool.usage or null != null) {
      usage = {readerPool = null;} // pool.usage;
    })
pools)
