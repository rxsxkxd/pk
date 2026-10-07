// 端末の判定。Android の Chrome では、accept が画像の <input type="file"> を開くと、Android 14 以降の
// フォトピッカーになり、カメラが選べない。Android だけ「カメラを起動」（capture 付き）を別に出すために使う。
// User-Agent Client Hints の platform（Chrome 90 以降）と User-Agent の両方を見る（どちらかで Android なら Android）。

type NavigatorUAData = { platform?: string };

export function isAndroid(nav: Navigator = navigator): boolean {
  const uaData = (nav as Navigator & { userAgentData?: NavigatorUAData }).userAgentData;
  return uaData?.platform === 'Android' || /Android/i.test(nav.userAgent);
}
