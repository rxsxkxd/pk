import React from "react";
import { createRoot } from "react-dom/client";

function Page() {
  return (
    <main data-testid="react-page">
      <h1>React ページ</h1>
      <p>Rails から React を表示しています。</p>
    </main>
  );
}

const root = document.getElementById("react-root");
if (root) createRoot(root).render(<Page />);
