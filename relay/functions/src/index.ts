import * as admin from "firebase-admin";
import * as functions from "firebase-functions/v2/https";
import { logger } from "firebase-functions/v2";

admin.initializeApp();

// Maximum notifications allowed per FCM token per day to guard against automation runaway.
const MAX_PER_TOKEN_PER_DAY = 150;

interface HANotificationPayload {
  message: string;
  title?: string;
  data?: {
    push?: {
      sound?: string;
      badge?: number;
      "interruption-level"?: string;
    };
    [key: string]: unknown;
  };
  registration_info?: {
    app_id?: string;
    app_version?: string;
    os_version?: string;
  };
}

// Rate-limit state is stored in Firestore under relay_rate_limits/{token_hash}/{date}.
async function isRateLimited(tokenHash: string): Promise<boolean> {
  const db = admin.firestore();
  const today = new Date().toISOString().slice(0, 10);
  const ref = db.collection("relay_rate_limits").doc(tokenHash).collection("days").doc(today);

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const count: number = snap.exists ? (snap.data()?.count ?? 0) : 0;
    if (count >= MAX_PER_TOKEN_PER_DAY) {
      return true;
    }
    tx.set(ref, { count: count + 1 }, { merge: true });
    return false;
  });
}

function sha256Hex(input: string): string {
  const { createHash } = require("crypto") as typeof import("crypto");
  return createHash("sha256").update(input).digest("hex");
}

export const pushRelay = functions.onRequest(
  {
    region: "us-central1",
    // Limit concurrency to reduce runaway Cloud Function costs.
    maxInstances: 10,
    timeoutSeconds: 30,
    memory: "128MiB",
  },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).json({ error: "Method not allowed" });
      return;
    }

    const body = req.body as { push_token?: string; message?: string } & HANotificationPayload;

    const fcmToken: string | undefined = body.push_token;
    if (!fcmToken || typeof fcmToken !== "string") {
      res.status(422).json({ error: "Missing or invalid push_token" });
      return;
    }

    const tokenHash = sha256Hex(fcmToken);
    if (await isRateLimited(tokenHash)) {
      logger.warn("Rate limit exceeded", { tokenHash });
      res.status(429).json({ error: "Rate limit exceeded" });
      return;
    }

    const title = body.title ?? "Hassonic";
    const message = body.message ?? "";
    const pushData = body.data?.push ?? {};

    const apnsPayload: admin.messaging.ApnsPayload = {
      payload: {
        aps: {
          alert: { title, body: message },
          sound: (pushData.sound as string | undefined) ?? "default",
          badge: pushData.badge,
          "interruption-level": (pushData["interruption-level"] as admin.messaging.ApsAlert["launchImageName"] | undefined) as never,
        },
      },
    };

    // Forward any non-push keys as FCM data so automations can pass arbitrary data.
    const dataFields: Record<string, string> = {};
    if (body.data) {
      for (const [k, v] of Object.entries(body.data)) {
        if (k !== "push" && v !== undefined) {
          dataFields[k] = typeof v === "string" ? v : JSON.stringify(v);
        }
      }
    }

    try {
      await admin.messaging().send({
        token: fcmToken,
        notification: { title, body: message },
        apns: apnsPayload,
        data: dataFields,
      });
      res.status(201).json({ rationale: "push sent" });
    } catch (err) {
      logger.error("FCM send failed", err);
      res.status(500).json({ error: "Failed to send notification" });
    }
  }
);
