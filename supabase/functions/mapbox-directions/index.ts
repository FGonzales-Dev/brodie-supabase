// Directions proxy. The app requests routes here instead of calling Mapbox
// with the token compiled into the APK. Every call is checked against the
// per-user and global daily limits in the api_quotas table before it reaches
// Mapbox, so usage (and the Mapbox bill) can't run past them.
//
// Request:  POST { "coordinates": [[lng, lat], [lng, lat], ...] }   (2–25 points)
// Response: 200 { "polyline6": string, "distance_m": number, "duration_s": number,
//                 "maneuvers": [{ "instruction": string, "type": string, "modifier": string | null,
//                                 "lng": number, "lat": number }] }
//           400 invalid input · 401 not signed in · 404 no route
//           429 daily limit reached · 502 Mapbox error
import { adminClient, getCaller, isLngLat, json, mapboxToken, readJsonObject } from "../_shared/proxy.ts";

const MAX_POINTS = 25; // Mapbox driving-profile limit

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const user = await getCaller(req);
  if (!user) return json(401, { error: "unauthorized" });

  const coordinates = (await readJsonObject(req))?.coordinates;
  if (!isValidCoordinates(coordinates)) return json(400, { error: "invalid_coordinates" });

  const { data: allowed, error: quotaError } = await adminClient().rpc("consume_api_quota", {
    p_user_id: user.id,
    p_api_name: "mapbox_directions",
  });
  if (quotaError) return json(500, { error: "quota_check_failed" });
  if (!allowed) return json(429, { error: "rate_limited" });

  const token = mapboxToken();
  if (!token) return json(500, { error: "not_configured" });

  const path = coordinates.map(([lng, lat]) => `${lng},${lat}`).join(";");
  const url = new URL(`https://api.mapbox.com/directions/v5/mapbox/driving/${path}`);
  url.search = new URLSearchParams({
    geometries: "polyline6",
    overview: "full",
    // Turn instructions for the ride screen; same request, same price.
    steps: "true",
    alternatives: "false",
    access_token: token,
  }).toString();

  const response = await fetch(url);
  if (!response.ok) return json(502, { error: "upstream_error", status: response.status });

  const route = (await response.json()).routes?.[0];
  if (!route) return json(404, { error: "no_route" });
  return json(200, {
    polyline6: route.geometry,
    distance_m: route.distance,
    duration_s: route.duration,
    maneuvers: (route.legs ?? []).flatMap(toManeuvers),
  });
});

// deno-lint-ignore no-explicit-any
function toManeuvers(leg: Record<string, any>) {
  // deno-lint-ignore no-explicit-any
  return (leg.steps ?? []).map(({ maneuver }: Record<string, any>) => ({
    instruction: maneuver.instruction,
    type: maneuver.type,
    modifier: maneuver.modifier ?? null,
    lng: maneuver.location[0],
    lat: maneuver.location[1],
  }));
}

function isValidCoordinates(value: unknown): value is [number, number][] {
  return Array.isArray(value) && value.length >= 2 && value.length <= MAX_POINTS && value.every(isLngLat);
}
