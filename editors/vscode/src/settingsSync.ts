// Whether a change of the zfls settings can be sent to a running server
// (workspace/didChangeConfiguration) or needs it restarted. No VS Code here,
// so that test/unit can run it with plain Node.js.

/** zfls's settings under the names of its configuration file */
export type ServerSettings = Record<string, unknown>;

const FORMATTERS = ["findent", "fprettify"];

/** The features that the server announces when it starts, or registers when
 * a setting turns them on */
function providers(s: ServerSettings): boolean[] {
  return [
    s.use_signature_help === true,
    s.enable_code_actions === true || s.fortitude === true,
    FORMATTERS.includes(String(s.formatter)) || FORMATTERS.includes(String(s.formatter_fixed)),
  ];
}

/** Whether a running server that has the settings `prev` can take `next`
 * without a restart: not when `next` leaves out a setting that `prev` has
 * (the server would keep its command line's value, which was `prev`'s), nor
 * when a feature is turned off (the editor would keep offering it) */
export function appliesLive(prev: ServerSettings, next: ServerSettings): boolean {
  if (Object.keys(prev).some((k) => !(k in next))) {
    return false;
  }
  const before = providers(prev);
  const after = providers(next);
  return before.every((on, i) => !on || after[i]);
}
