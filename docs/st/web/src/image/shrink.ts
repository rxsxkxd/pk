// 上限（config.json の maxImageBytes）を超えた写真だけを、ブラウザで縮めて JPEG にする（notes/image-compression.md 7.1）。
// 上限以下の写真はここを通らず、今までどおり加工せずに送る。圧縮は Compressor.js（向きの補正、EXIF の除去を含む）。

import Compressor from 'compressorjs';

export type ShrinkStep = { maxSize: number; quality: number };

// 上限に収まるまで順に試す。解像度（証明書の文字）をなるべく残す順。4096 は iOS の canvas の上限。
export const SHRINK_STEPS: readonly ShrinkStep[] = [
  { maxSize: 4096, quality: 0.9 },
  { maxSize: 4096, quality: 0.8 },
  { maxSize: 3072, quality: 0.8 },
  { maxSize: 2048, quality: 0.8 },
];

// Compressor.js reads the whole file to fix the orientation; its README advises turning that off for very large
// files (out of memory). Above this size the browser's own orientation handling is used.
const CHECK_ORIENTATION_UP_TO = 10_000_000;

export type Compress = (file: File, step: ShrinkStep) => Promise<Blob>;

// 1回の圧縮（長辺を step.maxSize 以下にし、step.quality の JPEG にする）。
export const compressJpeg: Compress = (file, { maxSize, quality }) =>
  new Promise((resolve, reject) => {
    new Compressor(file, {
      maxWidth: maxSize,
      maxHeight: maxSize,
      quality,
      mimeType: 'image/jpeg',
      checkOrientation: file.size <= CHECK_ORIENTATION_UP_TO,
      success: resolve,
      error: reject,
    });
  });

// SHRINK_STEPS の順に圧縮し、maxBytes 以下になった最初の結果を返す。どれでも収まらないか、圧縮できない
// （デコードできない HEIC など）ときは undefined（呼び出し側は「大きすぎます」を出す）。
export async function shrinkToFit(
  file: File,
  maxBytes: number,
  compress: Compress = compressJpeg,
): Promise<File | undefined> {
  for (const step of SHRINK_STEPS) {
    let blob: Blob;
    try {
      blob = await compress(file, step);
    } catch {
      return undefined;
    }
    if (blob.size <= maxBytes) {
      return new File([blob], jpegName(file.name), { type: 'image/jpeg', lastModified: file.lastModified });
    }
  }
  return undefined;
}

// IMG_0001.HEIC → IMG_0001.jpg（API は名前を使わないが、送るファイルの形式と名前をそろえる）。
export function jpegName(name: string): string {
  const base = name.replace(/\.[^./\\]+$/, '');
  return `${base || 'image'}.jpg`;
}
