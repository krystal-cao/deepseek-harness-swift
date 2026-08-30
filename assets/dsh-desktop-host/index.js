import { startDesktopControl } from "./control.js";

export const name = "dsh-desktop-host";

// The profile Loader imports this entry after the replacement webserver. Start
// control eagerly as a second, idempotent safety net; the webserver constructor
// also starts it so requests remain denied during any activation ordering.
export function apply() {
  startDesktopControl();
}
