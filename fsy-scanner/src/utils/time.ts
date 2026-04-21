export function nowMs(): number {
  return Date.now();
}

export function formatDisplay(ts: number): string {
  return new Date(ts).toLocaleString();
}
