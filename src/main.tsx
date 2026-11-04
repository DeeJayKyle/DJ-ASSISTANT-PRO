import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import { AccountGate } from "./components/Accounts";
import "./styles.css";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <AccountGate>{(id) => <App key={id} />}</AccountGate>
  </StrictMode>,
);
