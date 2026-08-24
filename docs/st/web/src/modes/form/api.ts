// フォーム送信方式（オプション）の API: fetch は使わず、普通のフォームの送信先（action）にするだけ。

// チケット発行 API。ブラウザのフォーム送信（Accept: text/html）なので、API は 303 で API のチケット表示
// ページに移す（SPA には戻らない）。
export function grantFormAction(apiBaseUrl: string): string {
  return `${apiBaseUrl}/v1/tickets`;
}
