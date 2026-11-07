import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { ReactFlowHook } from "./hooks/react_flow_hook";
import { ScrubberHook } from "./hooks/scrubber_hook";

const Hooks = {
  ReactFlowHook,
  ScrubberHook,
};

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
});

liveSocket.connect();
window.liveSocket = liveSocket;
