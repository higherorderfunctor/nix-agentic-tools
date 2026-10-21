// R01 kimchi src/regions.ts + resolveEndpoints + class baseUrl shape
export const REGIONS = {
  us: {
    webAppUrl: "https://r01-app-us.test",
    castApiUrl: "https://r01-api-us.test",
  },
  eu: {
    webAppUrl: "https://r01-app-eu.test",
    castApiUrl: "https://r01-api-eu.test",
  },
} as const;
type RegionId = keyof typeof REGIONS;
function endpointsForRegion(region: RegionId) {
  const r = REGIONS[region];
  return { castApiUrl: r.castApiUrl, webAppUrl: r.webAppUrl };
}
export function resolveEndpoints() {
  return endpointsForRegion((process.env.REGION as RegionId) ?? "us");
}
async function fetchWithRetry(url: string, init?: RequestInit) {
  const f = globalThis.fetch;
  return f(url, init);
}
export class StatsApi {
  private baseUrl: string;
  constructor(config: { baseUrl?: string } = {}) {
    this.baseUrl = config.baseUrl ?? resolveEndpoints().castApiUrl;
  }
  async get(path: string) {
    const url = `${this.baseUrl}${path}`;
    return fetchWithRetry(url);
  }
}
export const r01 = () => new StatsApi().get("/v1/stats");
// R02 the web app URL only opened in a browser, never fetched: negative control
export function r02() {
  console.log(`${resolveEndpoints().webAppUrl}/login`);
}
// R03 static table read
export const r03 = () => fetch(`${REGIONS.us.castApiUrl}/v1/r03`);
// R04 dynamic table read straight into the request
export const r04 = (id: RegionId) => fetch(`${REGIONS[id].castApiUrl}/v1/r04`);
// R05 class field set from a literal default, no table
class Plain {
  private baseUrl: string;
  constructor(b?: string) {
    this.baseUrl = b ?? "https://r05-field.test";
  }
  get(p: string) {
    return fetch(`${this.baseUrl}${p}`);
  }
}
export const r05 = () => new Plain().get("/v1");
// R06 kimchi's spread: endpoints built by spreading a resolved region
function regionEndpoints(r: { castApiUrl: string }) {
  return { castApiUrl: r.castApiUrl, statsUrl: `${r.castApiUrl}/stats` };
}
function endpointsSpread(id: RegionId) {
  const resolved = REGIONS[id];
  const e = regionEndpoints(resolved);
  return { ...e, extra: process.env.R06_EXTRA ?? e.statsUrl };
}
export const r06 = (id: RegionId) => fetch(endpointsSpread(id).extra);
