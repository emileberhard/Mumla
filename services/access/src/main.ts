import { CloudKitIdentity } from "./cloudkit";
import { readConfig } from "./config";
import { maximumAudioSeconds, OperatorIncident } from "./protocol";
import { checkRouter } from "./readiness";
import { AccessService } from "./server";
import { AccessStore, validateSnapshot } from "./store";

declare const ACCESS_VERSION: string;
declare const ACCESS_COMMIT: string;

async function main() {
  const release = {
    version:
      typeof ACCESS_VERSION === "string" ? ACCESS_VERSION : "development",
    commit: typeof ACCESS_COMMIT === "string" ? ACCESS_COMMIT : "unreleased",
  };
  const args = Bun.argv.slice(2);
  if (args.length === 1 && args[0] === "version") {
    console.log(JSON.stringify(release));
    process.exit(0);
  }
  if (
    args.length !== 3 ||
    !["serve", "check", "init"].includes(args[0] ?? "") ||
    args[1] !== "--config" ||
    !args[2]
  ) {
    console.error(
      "Usage: mumla-access version | <serve|check|init> --config <private-json>",
    );
    process.exit(2);
  }
  process.umask(0o077);
  const config = await readConfig(args[2]);
  if (args[0] === "check") {
    validateSnapshot(config.database);
    const [, identityProven] = await Promise.all([
      checkRouter(config),
      new CloudKitIdentity(
        config.cloudKitContainer,
        config.cloudKitAPIToken,
      ).check(),
    ]);
    console.log(
      JSON.stringify({
        ...release,
        ready: identityProven,
        identity: identityProven ? "proven" : "unproven",
      }),
    );
    process.exit(identityProven ? 0 : 75);
  }
  const store = new AccessStore(
    config.database,
    config,
    args[0] === "init" ? "initialize" : "open",
  );
  if (args[0] === "init") {
    store.close();
    console.log(JSON.stringify({ ...release, initialized: true }));
    process.exit(0);
  }
  if (store.recoveredReservations)
    console.error(
      JSON.stringify({
        event: "access_service_incident",
        code: "recovered_reservations",
        count: store.recoveredReservations,
      }),
    );
  const stop = (code: number) => {
    void server.stop().then(() => {
      try {
        store.close();
      } finally {
        process.exit(code);
      }
    });
  };
  const service = new AccessService(
    config,
    new CloudKitIdentity(config.cloudKitContainer, config.cloudKitAPIToken),
    store,
    release,
    () => stop(1),
  );
  await service.check();
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: config.listenPort,
    maxRequestBodySize: maximumAudioSeconds * 32_000 + 16 * 1024,
    idleTimeout: 255,
    fetch(request) {
      return service.handle(request, request.headers.get("cf-connecting-ip"));
    },
    error() {
      return Response.json(
        { error: { code: "service_unavailable" } },
        { status: 503 },
      );
    },
  });
  process.on("SIGTERM", () => {
    if (!service.fenceForShutdown()) {
      console.error(
        JSON.stringify({
          event: "access_service_incident",
          code: "shutdown_while_active",
        }),
      );
      return;
    }
    stop(0);
  });
  console.log(JSON.stringify({ event: "access_service_started", ...release }));
}
void main().catch((error) => {
  console.error(
    JSON.stringify({
      event: "access_service_incident",
      code: error instanceof OperatorIncident ? error.code : "startup_failed",
    }),
  );
  process.exit(1);
});
