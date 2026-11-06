import { generateKeyPairSync, randomInt } from "node:crypto";
import jwt from "jsonwebtoken";
import { KEYUTIL, KJUR } from "jsrsasign";
import { AppStoreVerifier } from "../src/appstore";

export const syntheticApp = {
  appStoreBundleId: "example.synthetic.app",
  appStoreAppId: 1_000_000_001,
  subscriptionGroupId: "20000001",
};

export const syntheticPolicy = {
  proMonthlySeconds: 108_000,
  sandboxProMonthlySeconds: 7200,
  ...syntheticApp,
};

function keyPair() {
  const { privateKey, publicKey } = generateKeyPairSync("ec", {
    namedCurve: "P-256",
  });
  return {
    privatePem: privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
    publicPem: publicKey.export({ type: "spki", format: "pem" }).toString(),
  };
}

function certificate(
  subject: string,
  issuer: string,
  subjectKey: string,
  issuerKey: string,
  extensions: object[],
) {
  const value = new KJUR.asn1.x509.Certificate({
    version: 3,
    serial: { int: randomInt(1, 2 ** 31) },
    issuer: { str: issuer },
    subject: { str: subject },
    notbefore: "20250101000000Z",
    notafter: "20450101000000Z",
    sbjpubkey: KEYUTIL.getKey(subjectKey),
    ext: extensions,
    sigalg: "SHA256withECDSA",
    cakey: KEYUTIL.getKey(issuerKey),
  } as unknown as ConstructorParameters<typeof KJUR.asn1.x509.Certificate>[0]);
  return Buffer.from(value.getEncodedHex(), "hex");
}

const root = keyPair();
const intermediate = keyPair();
const leaf = keyPair();
export const syntheticRoot = certificate(
  "/CN=Synthetic Root",
  "/CN=Synthetic Root",
  root.publicPem,
  root.privatePem,
  [{ extname: "basicConstraints", cA: true }],
);
const intermediateCertificate = certificate(
  "/CN=Synthetic Intermediate",
  "/CN=Synthetic Root",
  intermediate.publicPem,
  root.privatePem,
  [
    { extname: "basicConstraints", cA: true },
    { extname: "1.2.840.113635.100.6.2.1", extn: "0500" },
  ],
);
const leafCertificate = certificate(
  "/CN=Synthetic Leaf",
  "/CN=Synthetic Intermediate",
  leaf.publicPem,
  intermediate.privatePem,
  [{ extname: "1.2.840.113635.100.6.11.1", extn: "0500" }],
);

export function sign(payload: object) {
  return jwt.sign(payload, leaf.privatePem, {
    algorithm: "ES256",
    noTimestamp: true,
    header: {
      alg: "ES256",
      x5c: [leafCertificate, intermediateCertificate, syntheticRoot].map(
        (value) => value.toString("base64"),
      ),
    },
  });
}

const day = 24 * 60 * 60 * 1000;

export function transaction(fields: Record<string, unknown> = {}) {
  const now = Date.now();
  return {
    transactionId: "2000000000000001",
    originalTransactionId: "2000000000000001",
    bundleId: syntheticApp.appStoreBundleId,
    productId: "example.synthetic.app.subscription.monthly",
    subscriptionGroupIdentifier: syntheticApp.subscriptionGroupId,
    purchaseDate: now - day,
    originalPurchaseDate: now - day,
    expiresDate: now + 29 * day,
    quantity: 1,
    type: "Auto-Renewable Subscription",
    inAppOwnershipType: "PURCHASED",
    signedDate: now,
    environment: "Sandbox",
    transactionReason: "PURCHASE",
    ...fields,
  };
}

export function notification(
  signedTransactionInfo: string | undefined,
  environment = "Sandbox",
) {
  return sign({
    notificationType: signedTransactionInfo ? "DID_RENEW" : "TEST",
    notificationUUID: crypto.randomUUID(),
    version: "2.0",
    signedDate: Date.now(),
    data: {
      bundleId: syntheticApp.appStoreBundleId,
      appAppleId: syntheticApp.appStoreAppId,
      environment,
      ...(signedTransactionInfo ? { signedTransactionInfo } : {}),
    },
  });
}

export function syntheticVerifier() {
  return new AppStoreVerifier(syntheticApp, [syntheticRoot]);
}
