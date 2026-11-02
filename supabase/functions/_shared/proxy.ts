// Shared by the Mapbox proxy functions (mapbox-directions, mapbox-search):
// JSON responses, caller authentication, the service-role client for quota
// checks, and the server-side Mapbox token.
import { createClient, type SupabaseClient, type User } from "npm:@supabase/supabase-js@2";

export const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

/** The signed-in caller, or null. Works with legacy and new JWT signing keys. */
export async function getCaller(req: Request): Promise<User | null> {
  const asCaller = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user }, error } = await asCaller.auth.getUser();
  return error ? null : user;
}

/** Service-role client: the quota functions are callable only with it. */
export const adminClient = (): SupabaseClient =>
  createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

export const mapboxToken = (): string | undefined => Deno.env.get("MAPBOX_SECRET_TOKEN");

/** The request body as a JSON object, or null when it isn't one. */
export async function readJsonObject(req: Request): Promise<Record<string, unknown> | null> {
  try {
    const body = await req.json();
    return body !== null && typeof body === "object" && !Array.isArray(body) ? body : null;
  } catch {
    return null;
  }
}

export const isLngLat = (value: unknown): value is [number, number] =>
  Array.isArray(value) &&
  value.length === 2 &&
  value.every((n) => typeof n === "number" && Number.isFinite(n)) &&
  Math.abs(value[0]) <= 180 &&
  Math.abs(value[1]) <= 90;
