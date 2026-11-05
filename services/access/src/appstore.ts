import {
  Environment,
  type JWSTransactionDecodedPayload,
  SignedDataVerifier,
  VerificationException,
  VerificationStatus,
} from "@apple/app-store-server-library";
import { appleRootCAG3 } from "./apple-root";
import { AccessError, parseJSON, record } from "./protocol";

export type StoreEnvironment = "Production" | "Sandbox";

export interface SignedTransaction {
  environment: StoreEnvironment;
  transactionId: string;
  originalTransactionId: string;
  appAccountToken: string | null;
  purchased: number;
  expires: number;
  revoked: number | null;
  signed: number;
}

export interface PurchaseVerifier {
  transaction(jws: string): Promise<SignedTransaction>;
  notification(signedPayload: string): Promise<SignedTransaction | null>;
}

export interface AppStoreApp {
  appStoreBundleId: string;
  appStoreAppId: number;
  subscriptionGroupId: string;
}

const identifier = /^[0-9]{1,32}$/;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function invalid(): never {
  throw new AccessError(400, "invalid_purchase");
}

function environment(value: unknown): StoreEnvironment {
  if (value === "Production" || value === "Sandbox") return value;
  invalid();
}

function claims(jws: string) {
  const parts = jws.split(".");
  if (parts.length !== 3 || !parts[1]) invalid();
  try {
    return record(parseJSON(Buffer.from(parts[1], "base64url").toString()));
  } catch {
    invalid();
  }
}

async function verified<T>(work: Promise<T>) {
  try {
    return await work;
  } catch (error) {
    if (!(error instanceof VerificationException)) throw error;
    if (error.status === VerificationStatus.RETRYABLE_VERIFICATION_FAILURE)
      throw new AccessError(503, "service_unavailable");
    invalid();
  }
}

function instant(value: unknown) {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0)
    invalid();
  return value;
}

export class AppStoreVerifier implements PurchaseVerifier {
  private readonly verifiers: Record<StoreEnvironment, SignedDataVerifier>;

  constructor(
    private readonly app: AppStoreApp,
    roots: Buffer[] = [appleRootCAG3],
  ) {
    this.verifiers = {
      Production: new SignedDataVerifier(
        roots,
        false,
        Environment.PRODUCTION,
        app.appStoreBundleId,
        app.appStoreAppId,
      ),
      Sandbox: new SignedDataVerifier(
        roots,
        false,
        Environment.SANDBOX,
        app.appStoreBundleId,
      ),
    };
  }

  async transaction(jws: string) {
    const verifier = this.verifiers[environment(claims(jws).environment)];
    return this.subscription(
      await verified(verifier.verifyAndDecodeTransaction(jws)),
    );
  }

  async notification(signedPayload: string) {
    const data = claims(signedPayload).data;
    if (data === undefined) return null;
    const verifier = this.verifiers[environment(record(data).environment)];
    const payload = await verified(
      verifier.verifyAndDecodeNotification(signedPayload),
    );
    const signed = payload.data?.signedTransactionInfo;
    if (signed === undefined) return null;
    const transaction = await verified(
      verifier.verifyAndDecodeTransaction(signed),
    );
    try {
      return this.subscription(transaction);
    } catch (error) {
      if (error instanceof AccessError) return null;
      throw error;
    }
  }

  private subscription(
    payload: JWSTransactionDecodedPayload,
  ): SignedTransaction {
    const token = payload.appAccountToken?.toLowerCase() || null;
    if (
      payload.subscriptionGroupIdentifier !== this.app.subscriptionGroupId ||
      payload.type !== "Auto-Renewable Subscription" ||
      payload.inAppOwnershipType !== "PURCHASED" ||
      typeof payload.transactionId !== "string" ||
      !identifier.test(payload.transactionId) ||
      typeof payload.originalTransactionId !== "string" ||
      !identifier.test(payload.originalTransactionId) ||
      (token !== null && !uuid.test(token))
    )
      invalid();
    return {
      environment: environment(payload.environment),
      transactionId: payload.transactionId,
      originalTransactionId: payload.originalTransactionId,
      appAccountToken: token,
      purchased: instant(payload.purchaseDate),
      expires: instant(payload.expiresDate),
      revoked:
        payload.revocationDate === undefined
          ? null
          : instant(payload.revocationDate),
      signed: instant(payload.signedDate),
    };
  }
}
