// Tailwind CSS 3.4 (v3-lts). Tailwind 4 needs Safari 16.4 / Chrome 111 and puts every style in @layer, which
// iOS 13–15.3 ignores entirely (notes/tailwind-compat.md). 3.4 outputs plain CSS with hex / rgb colors.
/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{vue,ts}'],
};
