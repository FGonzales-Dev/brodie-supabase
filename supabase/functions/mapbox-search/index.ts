// Place-search proxy. The app searches here instead of calling Mapbox with
// the token compiled into the APK. Mapbox bills search per session (suggest
// calls plus one retrieve sharing a session token), so each new session counts
// once against the per-user and global daily limits in the api_quotas table.
//
// Request:  POST { "action": "suggest", "q": string, "session_token": string, "proximity"?: [lng, lat] }
//           POST { "action": "retrieve", "id": string, "session_token": string }
// Response: suggest  200 { "suggestions": [{ "id": string, "name": string, "address": string | null }] }
//           retrieve 200 { "name": string, "address": string | null, "lng": number, "lat": number }
//           400 invalid input · 401 not signed in · 404 place not found
//           429 daily limit reached · 502 Mapbox error
import { adminClient, getCaller, isLngLat, json, mapboxToken, readJsonObject } from "../_shared/proxy.ts";

const MAX_REQUESTS_PER_SESSION = 50; // Mapbox's own per-session suggest limit
const SEARCH_URL = "https://api.mapbox.com/search/searchbox/v1";

type SearchRequest = { kind: "suggest" | "retrieve"; url: URL };
// deno-lint-ignore no-explicit-any
type MapboxJson = Record<string, any>;

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const user = await getCaller(req);
  if (!user) return json(401, { error: "unauthorized" });

  // Validate before touching the quota, so bad requests cost nothing.
  const body = await readJsonObject(req);
  const sessionToken = body?.session_token;
  if (typeof sessionToken !== "string" || sessionToken.length < 8 || sessionToken.length > 64) {
    return json(400, { error: "invalid_session_token" });
  }
  const request = buildRequest(body!, sessionToken);
  if (!request) return json(400, { error: "invalid_request" });

  const { data: allowed, error: quotaError } = await adminClient().rpc("consume_api_session", {
    p_user_id: user.id,
    p_api_name: "mapbox_search",
    p_session_token: sessionToken,
    p_max_requests: MAX_REQUESTS_PER_SESSION,
  });
  if (quotaError) return json(500, { error: "quota_check_failed" });
  if (!allowed) return json(429, { error: "rate_limited" });

  const token = mapboxToken();
  if (!token) return json(500, { error: "not_configured" });
  request.url.searchParams.set("access_token", token);

  const response = await fetch(request.url);
  if (!response.ok) return json(502, { error: "upstream_error", status: response.status });

  const data: MapboxJson = await response.json();
  if (request.kind === "suggest") {
    const suggestions: MapboxJson[] = data.suggestions ?? [];
    // Only suggestions with an id can be retrieved into a place.
    return json(200, { suggestions: suggestions.filter((item) => typeof item.mapbox_id === "string").map(toSuggestion) });
  }
  const feature = data.features?.[0];
  if (!feature) return json(404, { error: "not_found" });
  const [lng, lat] = feature.geometry.coordinates;
  return json(200, { name: feature.properties.name, address: addressOf(feature.properties), lng, lat });
});

function buildRequest(body: Record<string, unknown>, sessionToken: string): SearchRequest | null {
  if (body.action === "suggest") {
    const { q, proximity } = body;
    if (typeof q !== "string" || q.trim().length === 0 || q.length > 256) return null;
    if (proximity !== undefined && !isLngLat(proximity)) return null;

    const url = new URL(`${SEARCH_URL}/suggest`);
    url.searchParams.set("q", q);
    url.searchParams.set("session_token", sessionToken);
    url.searchParams.set("language", "en");
    url.searchParams.set("limit", "5");
    if (proximity) url.searchParams.set("proximity", `${proximity[0]},${proximity[1]}`);
    return { kind: "suggest", url };
  }

  if (body.action === "retrieve") {
    const { id } = body;
    // Place ids are short, but brand results (e.g. "Jollibee") carry ids of ~3k characters.
    if (typeof id !== "string" || id.length === 0 || id.length > 4096) return null;

    const url = new URL(`${SEARCH_URL}/retrieve/${encodeURIComponent(id)}`);
    url.searchParams.set("session_token", sessionToken);
    return { kind: "retrieve", url };
  }

  return null;
}

const addressOf = (item: MapboxJson): string | null => item.full_address ?? item.place_formatted ?? null;

const toSuggestion = (item: MapboxJson) => ({ id: item.mapbox_id, name: item.name, address: addressOf(item) });
