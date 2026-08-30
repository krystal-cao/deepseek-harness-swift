import { startDesktopControl, waitForDesktopBootstrap } from "./dsh-desktop-host/control.js";

function fail(error) {
  const detail = error instanceof Error ? error.message : String(error);
  process.stderr.write(`dsh runtime bootstrap failed: ${detail}\n`);
  process.exitCode = 1;
}

try {
  // The inherited stdin pipe is the only source of the DSH entry path and
  // runtime arguments. No user-controlled equivalent is accepted from argv.
  startDesktopControl();
  const bootstrap = await waitForDesktopBootstrap();

  process.title = "DSH Web Runtime";
  process.argv = [
    process.argv[0],
    bootstrap.entryPath,
    "--profile", bootstrap.profile,
    "--host", bootstrap.host,
    "--port", String(bootstrap.port),
    "--no-open",
  ];

  await import(bootstrap.entryPath);
} catch (error) {
  fail(error);
}
