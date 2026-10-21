import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { Home } from "./components/Home";
import { onPhone, routedToHome } from "./session";

if (onPhone) document.documentElement.classList.add("phone");

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    {routedToHome ? <Home /> : <App />}
  </StrictMode>,
);
