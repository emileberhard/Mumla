import { isAbsolute } from "node:path";
import { exactKeys, integer, parseJSON, record } from "./protocol";

export interface AccessConfig {
  listenPort: number;
  database: string;
  cloudKitContainer: string;
  cloudKitAPIToken: string;
  routerOrigin: string;
  routerKey: string;
  operatorToken: string;
  freeMonthlySeconds: number;
  subjectOverrides: Record<string, number>;
}

export async function readConfig(path: string): Promise<AccessConfig> {
  const file = Bun.file(path);
  if (file.size > 64 * 1024) throw new Error("Configuration is too large");
  const value = record(parseJSON(await file.text()));
  exactKeys(value, [
    "listenPort",
    "database",
    "cloudKitContainer",
    "cloudKitAPIToken",
    "routerOrigin",
    "routerKey",
    "operatorToken",
    "freeMonthlySeconds",
    "subjectOverrides",
  ]);
  for (const key of [
    "database",
    "cloudKitContainer",
    "cloudKitAPIToken",
    "routerOrigin",
    "routerKey",
    "operatorToken",
  ]) {
    if (typeof value[key] !== "string" || !value[key].trim()) {
      throw new Error(`Invalid configuration: ${key}`);
    }
  }
  const database = value.database as string;
  const container = value.cloudKitContainer as string;
  const origin = new URL(value.routerOrigin as string);
  if (
    !isAbsolute(database) ||
    !/^iCloud\.[A-Za-z0-9.-]+$/.test(container) ||
    origin.protocol !== "http:" ||
    !["127.0.0.1", "[::1]"].includes(origin.hostname) ||
    origin.pathname !== "/" ||
    origin.username ||
    origin.password ||
    origin.search ||
    origin.hash ||
    (value.operatorToken as string).length < 32
  ) {
    throw new Error("Invalid configuration boundary");
  }
  const overrides: Record<string, number> = {};
  for (const [subject, seconds] of Object.entries(
    record(value.subjectOverrides),
  )) {
    if (!/^[0-9a-f-]{36}$/.test(subject)) {
      throw new Error("Invalid subject override");
    }
    overrides[subject] = integer(seconds, 1, 31 * 24 * 3600);
  }
  return {
    listenPort: integer(value.listenPort, 1024, 65535),
    database,
    cloudKitContainer: container,
    cloudKitAPIToken: value.cloudKitAPIToken as string,
    routerOrigin: origin.origin,
    routerKey: value.routerKey as string,
    operatorToken: value.operatorToken as string,
    freeMonthlySeconds: integer(value.freeMonthlySeconds, 1, 31 * 24 * 3600),
    subjectOverrides: overrides,
  };
}
