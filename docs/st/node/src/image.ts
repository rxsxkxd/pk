// Format detection of uploaded images and the runtime size limit  (↔ go/internal/imageinput).
// A technical concern of the HTTP layer; which formats are accepted is a business rule in domain.ts.

import { imageSize } from 'image-size';

// Upload ceiling set by the runtime: a Lambda request is at most 6MB and binary bodies are base64 (×4/3).
// A deployment can lower it with MAX_IMAGE_BYTES (DESIGN.md 5).
export const MAX_IMAGE_BYTES = 4 << 20;

// image-size's type → MIME type (heic / mif1 are HEIF brands).
const DETECTED_TYPES: Record<string, string> = {
  jpg: 'image/jpeg',
  png: 'image/png',
  heic: 'image/heic',
  heif: 'image/heif',
  mif1: 'image/heif',
  avif: 'image/avif',
  webp: 'image/webp',
};

// 画像ヘッダーを image-size で解析して MIME タイプを返す（画像として読めなければ undefined）。
export function detectImageType(data: Uint8Array): string | undefined {
  try {
    return DETECTED_TYPES[imageSize(data).type ?? ''];
  } catch {
    return undefined;
  }
}
