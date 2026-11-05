import {
  APIException,
  AppStoreServerAPIClient,
  Environment,
  type NotificationHistoryResponse,
} from "@apple/app-store-server-library";

const bundleId = "emileberhard.WisprClone.ios";
const environments: Record<string, Environment> = {
  Production: Environment.PRODUCTION,
  Sandbox: Environment.SANDBOX,
};

function usage(): never {
  console.error(
    "Usage: MUMLA_IAP_KEY_PATH=… MUMLA_IAP_KEY_ID=… MUMLA_IAP_ISSUER_ID=… bun scripts/replay-notifications.ts <Production|Sandbox> <since ISO 8601> <service origin>",
  );
  process.exit(2);
}

async function retrying<T>(work: () => Promise<T>) {
  for (let attempt = 0; ; attempt++) {
    try {
      return await work();
    } catch (error) {
      const status = error instanceof APIException ? error.httpStatusCode : 0;
      if (attempt === 5 || (status !== 429 && status < 500)) throw error;
      await Bun.sleep(2 ** attempt * 1000 * (0.5 + Math.random()));
    }
  }
}

const [name, since, origin] = Bun.argv.slice(2);
const environment = environments[name ?? ""];
const startDate = Date.parse(since ?? "");
const { MUMLA_IAP_KEY_PATH, MUMLA_IAP_KEY_ID, MUMLA_IAP_ISSUER_ID } =
  process.env;
if (
  !environment ||
  !Number.isFinite(startDate) ||
  !origin ||
  !MUMLA_IAP_KEY_PATH ||
  !MUMLA_IAP_KEY_ID ||
  !MUMLA_IAP_ISSUER_ID
)
  usage();
const endpoint = new URL("/v1/app-store/notifications", origin);
const client = new AppStoreServerAPIClient(
  await Bun.file(MUMLA_IAP_KEY_PATH).text(),
  MUMLA_IAP_KEY_ID,
  MUMLA_IAP_ISSUER_ID,
  bundleId,
  environment,
);
const request = { startDate, endDate: Date.now() };
let paginationToken: string | null = null;
let posted = 0;
let failed = 0;
do {
  const token = paginationToken;
  const page: NotificationHistoryResponse = await retrying(() =>
    client.getNotificationHistory(token, request),
  );
  for (const { signedPayload } of page.notificationHistory ?? []) {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ signedPayload }),
    });
    if (response.ok) posted++;
    else {
      failed++;
      console.error(JSON.stringify({ status: response.status }));
    }
  }
  paginationToken = page.hasMore ? (page.paginationToken ?? null) : null;
} while (paginationToken);
console.log(JSON.stringify({ posted, failed }));
process.exit(failed ? 1 : 0);
