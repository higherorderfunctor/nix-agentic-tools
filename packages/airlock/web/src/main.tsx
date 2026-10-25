import { RegistryProvider } from "@effect/atom-react";
import { MantineProvider } from "@mantine/core";
import "@mantine/charts/styles.css";
import "@mantine/core/styles.css";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./views/App.tsx";

const root = document.getElementById("root");
if (root === null) throw new Error("missing root element");
createRoot(root).render(
  <StrictMode>
    <MantineProvider>
      <RegistryProvider>
        <App />
      </RegistryProvider>
    </MantineProvider>
  </StrictMode>,
);
