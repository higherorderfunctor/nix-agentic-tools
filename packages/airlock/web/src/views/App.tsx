import {
  Button,
  Container,
  Group,
  PasswordInput,
  Stack,
  Text,
  Title,
} from "@mantine/core";
import { useEffect, useMemo, useState } from "react";
import { fixtureAppRuntime } from "../data/app.ts";
import { Overview } from "./Overview.tsx";
import { ProviderHistory } from "./ProviderHistory.tsx";
import { RequestHistory } from "./RequestHistory.tsx";

const screens = ["overview", "providers", "requests"] as const;
type Screen = (typeof screens)[number];

function selectedScreen(): Screen {
  const hash = window.location.hash.slice(1);
  return screens.find((screen) => screen === hash) ?? "overview";
}

export function App() {
  const [screen, setScreen] = useState<Screen>(selectedScreen);
  const [tokenDraft, setTokenDraft] = useState("");
  const [token, setToken] = useState<string | null>(null);
  useEffect(() => {
    const onHash = () => setScreen(selectedScreen());
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);
  const runtime = useMemo(
    () =>
      token === null
        ? null
        : fixtureAppRuntime({
            url: `${window.location.protocol === "https:" ? "wss" : "ws"}://${window.location.host}/api/v1/live`,
            token,
          }),
    [token],
  );
  return (
    <Container size="xl" py="lg">
      <Stack>
        <header>
          <Title order={1}>Airlock usage</Title>
          <Text>Local read-only routing and usage observations</Text>
        </header>
        {runtime === null ? (
          <form
            onSubmit={(event) => {
              event.preventDefault();
              if (tokenDraft.trim()) {
                setToken(tokenDraft.trim());
                setTokenDraft("");
              }
            }}
          >
            <Stack>
              <PasswordInput
                label="Airlock read token"
                description="Held in this page's memory only"
                value={tokenDraft}
                onChange={(event) => setTokenDraft(event.currentTarget.value)}
                autoComplete="off"
                required
              />
              <Button type="submit">Connect</Button>
            </Stack>
          </form>
        ) : (
          <>
            <nav aria-label="Screens">
              <Group>
                {screens.map((entry) => (
                  <Button
                    key={entry}
                    component="a"
                    href={`#${entry}`}
                    variant={screen === entry ? "filled" : "light"}
                  >
                    {entry === "providers"
                      ? "Provider history"
                      : entry === "requests"
                        ? "Request history"
                        : "Overview"}
                  </Button>
                ))}
                <Button variant="subtle" onClick={() => setToken(null)}>
                  Disconnect
                </Button>
              </Group>
            </nav>
            <main>
              {screen === "overview" ? (
                <Overview runtime={runtime} />
              ) : screen === "providers" ? (
                <ProviderHistory runtime={runtime} />
              ) : (
                <RequestHistory runtime={runtime} />
              )}
            </main>
          </>
        )}
      </Stack>
    </Container>
  );
}
