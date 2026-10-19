export function parseFirebaseServiceAccount(_v: string) {
  return { projectId: "synthetic" };
}
export async function getFirebaseAccessToken(_v: unknown) {
  (globalThis as any).__oauthCalls++;
  return "synthetic";
}
