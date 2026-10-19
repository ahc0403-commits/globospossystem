export function serve(handler: (req: Request) => Promise<Response>) {
  (globalThis as any).__handlers.push(handler);
}
