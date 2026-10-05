// チケットコードの先頭14桁（YYYYMMDDHHmmss、日本時間）を「YYYY-MM-DD HH:mm:ss」にする。
export function issuedAtFromCode(code: string): string {
  const m = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/.exec(code);
  return m ? `${m[1]}-${m[2]}-${m[3]} ${m[4]}:${m[5]}:${m[6]}` : '';
}

// API の issuedAt（RFC 3339、+09:00）を「YYYY-MM-DD HH:mm:ss」にする。
export function formatIssuedAt(issuedAt: string): string {
  return issuedAt.slice(0, 19).replace('T', ' ');
}
