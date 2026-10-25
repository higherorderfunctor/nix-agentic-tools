{facetOwner, ...}: {
  documentation.genericDescriptions.airlock = "Credential-injecting egress gateway for coding harnesses";
  fragments.categories = {
    airlock = {
      scopes = ["packages/${facetOwner}/**"];
      sources = [
        {
          dir = facetOwner;
          location = "package";
          name = "airlock";
        }
      ];
    };
    airlock-control = {
      scopes = ["packages/${facetOwner}/**"];
      sources = [
        {
          dir = facetOwner;
          location = "package";
          name = "control";
        }
      ];
    };
    airlock-integration = {
      scopes = ["packages/${facetOwner}/**"];
      sources = [
        {
          dir = facetOwner;
          location = "package";
          name = "integration";
        }
      ];
    };
    airlock-oauth = {
      scopes = ["packages/${facetOwner}/**"];
      sources = [
        {
          dir = facetOwner;
          location = "package";
          name = "oauth";
        }
      ];
    };
    airlock-routing = {
      scopes = ["packages/${facetOwner}/**"];
      sources = [
        {
          dir = facetOwner;
          location = "package";
          name = "routing";
        }
      ];
    };
    airlock-storage = {
      scopes = ["packages/${facetOwner}/**"];
      sources = [
        {
          dir = facetOwner;
          location = "package";
          name = "storage";
        }
      ];
    };
    airlock-usage-storage = {
      scopes = ["packages/${facetOwner}/**"];
      sources = [
        {
          dir = facetOwner;
          location = "package";
          name = "usage-storage";
        }
      ];
    };
  };
}
