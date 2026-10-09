import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  createAgentStep,
  createStep,
  createWorkflow,
} from "@kimchi-dev/kimchi-workflows";
import { Type } from "typebox";
import type { Profile } from "../kimchi/workflow.ts";

export type TransportProfile = {
  roles: { lens: Profile["roles"]["lens"] } & Record<
    string,
    Profile["roles"]["lens"]
  >;
} & Partial<Pick<Profile, "defense_policy" | "limits">>;
const receipt = fileURLToPath(new URL("./receipt.py", import.meta.url));
const object = Type.Unsafe<Record<string, any>>({ type: "object" });
function guard(
  phase: string,
  request: string,
  terminal = false,
  digest?: string,
  binding?: Record<string, unknown>,
) {
  const args = [receipt, "--phase", phase, "--request", request];
  if (terminal) args.push("--terminal");
  if (digest) args.push("--request-digest", digest);
  if (binding) args.push("--binding", JSON.stringify(binding));
  return JSON.parse(execFileSync("@python@", args, { encoding: "utf8" }));
}
export function createTransportWorkflow(
  phase: "pull" | "push",
  profile: TransportProfile,
) {
  const model = profile?.roles?.lens?.model_id;
  if (typeof model !== "string" || !/^[^\s<>]+\/[^\s<>]+$/.test(model))
    throw new Error("explicit served Kimchi provider/modelId required");
  if (!["pull", "push"].includes(phase))
    throw new Error("phase must be pull or push");
  const common = readFileSync(
    new URL("./prompts/native.md", import.meta.url),
    "utf8",
  );
  const prompt = readFileSync(
    new URL(`./prompts/${phase}.md`, import.meta.url),
    "utf8",
  );
  const api = fileURLToPath(new URL("./API.md", import.meta.url));
  const helper = fileURLToPath(new URL("./local.py", import.meta.url));
  return createWorkflow({
    name: `gitlab-${phase}`,
    input: Type.Object({ request_file: Type.String() }),
    maxConcurrency: 1,
  })
    .then(
      createStep({
        name: "preflight",
        output: object,
        run: ({ ctx }) =>
          guard(
            phase,
            ctx.getInitData<{ request_file: string }>()!.request_file,
          ),
      }),
    )
    .then(
      createAgentStep({
        name: "transport",
        background: true,
        model,
        thinking: profile.roles.lens.effort,
        input: object,
        prompt: ({ input }) =>
          `${prompt}\n\nLocal API: ${api}\nHelper: @python@ ${JSON.stringify(helper)}\nValidated fixed request: ${JSON.stringify(input)}\n${common}`,
      }),
    )
    .then(
      createStep({
        name: "verified-receipt",
        output: object,
        run: ({ ctx }) => {
          const initial = ctx.getStepResult<Record<string, any>>("preflight")!;
          return guard(
            phase,
            initial.request_file,
            true,
            initial.request_digest,
            initial.binding,
          );
        },
      }),
    )
    .commit();
}
