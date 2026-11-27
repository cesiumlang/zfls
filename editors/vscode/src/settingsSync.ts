// Whether a change of the zfls settings can be sent to a running server
// (workspace/didChangeConfiguration) or needs it restarted. No VS Code here,
// so that test/unit can run it with plain Node.js.

/** zfls's settings under the names of its configuration file */
export type ServerSettings = Record<string, unknown>;

/** The values of zfls.formatting.formatter that name a formatter */
export const FORMATTERS = ["findent", "fprettify", "codee", "forformat", "custom", "zfls"];

/** The features that the server announces when it starts, or registers when
 * a setting turns them on */
function providers(s: ServerSettings): boolean[] {
  return [
    s.use_signature_help === true,
    s.enable_code_actions === true || s.fortitude === true,
    FORMATTERS.includes(String(s.formatter)) || FORMATTERS.includes(String(s.formatter_fixed)),
  ];
}

/** `s` without the settings that the options in `args` (`zfls.arguments`)
 * set: on the command line they come after the typed settings, and the
 * settings sent over LSP would take over from them. An option is named as
 * zfls reads it: in full, or by a prefix (all settings it begins, so as
 * not to leave in the one zfls would take); `-n` is `--nthreads`. */
export function withoutArguments(s: ServerSettings, args: readonly string[]): ServerSettings {
  const names = args.flatMap((arg) => {
    if (arg.startsWith("--")) {
      return [arg.slice(2).split("=")[0]];
    }
    return /^-n/.test(arg) ? ["nthreads"] : [];
  });
  const named = (key: string) => names.some((n) => n === key || (n !== "" && key.startsWith(n) && !(n in s)));
  return Object.fromEntries(Object.entries(s).filter(([key]) => !named(key)));
}

/** Whether a running server that has the settings `prev` can take `next`
 * without a restart: not when `next` leaves out a setting that `prev` has
 * (the server would keep its command line's value, which was `prev`'s), nor
 * when a feature is turned off (the editor would keep offering it), nor
 * when workspace diagnostics are turned on (the server needs them at start) */
export function appliesLive(prev: ServerSettings, next: ServerSettings): boolean {
  if (Object.keys(prev).some((k) => !(k in next))) {
    return false;
  }
  // the client pulls the workspace's diagnostics only if told so at start
  if (next.workspace_diagnostics === true && prev.workspace_diagnostics !== true) {
    return false;
  }
  const before = providers(prev);
  const after = providers(next);
  return before.every((on, i) => !on || after[i]);
}
