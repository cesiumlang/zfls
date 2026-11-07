// The module variables of a debugged Fortran program: the expressions that
// name a module's variable to each debugger, as each compiler names it in
// the program. No `vscode` import (see test/unit).

/** A module variable as a line sees it (`zfls/moduleVariables`) */
export interface ModuleVariable {
  /** the module that declares it */
  module: string;
  /** its name there */
  name: string;
  /** its name at the line (a USE may rename it) */
  local: string;
  /** its type (`REAL(8)`, `TYPE(grid)`, ...) */
  type: string;
}

/** The forms of a module variable's name, by who knows it:
 * - `module::name`: gdb, in a Fortran frame
 * - `__module_MOD_name`: gfortran's symbol, for lldb and C expressions
 * - `_QMmoduleEname`: LLVM Flang's symbol
 * - `MODULE_mp_NAME`: Intel's (ifx, ifort), for the Visual Studio debugger */
export type NameForm = "gdb" | "gfortran" | "flang" | "intel";

export const FORMS: readonly NameForm[] = ["gdb", "gfortran", "flang", "intel"];

/** The forms to try with a debug type, the likeliest first */
export function formsFor(debugType: string): NameForm[] {
  switch (debugType) {
    case "cppdbg":
    case "gdb":
      return ["gdb", "gfortran", "flang", "intel"];
    case "lldb":
      return ["gfortran", "flang", "gdb"];
    case "cppvsdbg":
      return ["intel", "flang", "gfortran"];
    default:
      return [...FORMS];
  }
}

/** The expression of a module variable in a form */
export function expression(form: NameForm, module: string, name: string): string {
  const m = module.toLowerCase();
  const n = name.toLowerCase();
  switch (form) {
    case "gdb":
      return `${m}::${n}`;
    case "gfortran":
      return `__${m}_MOD_${n}`;
    case "flang":
      return `_QM${m}E${n}`;
    case "intel":
      return `${m.toUpperCase()}_mp_${n.toUpperCase()}`;
  }
}

/** The forms to try, the one that worked last (in this debug session) first */
export function tryOrder(debugType: string, worked?: NameForm): NameForm[] {
  const forms = formsFor(debugType);
  return worked && forms.includes(worked) ? [worked, ...forms.filter((f) => f !== worked)] : forms;
}

/** Whether an evaluation's result is a debugger's error rather than a
 * value (most debuggers fail the request instead) */
export function isErrorValue(result: string): boolean {
  const r = result.trim();
  return (
    /^(<error|<could not|error:|No symbol|unable to|identifier .* is undefined)/i.test(r) ||
    / has unknown type; cast it/.test(r)
  );
}

/** The modules of a list of variables, in order, with their variables */
export function byModule(vars: readonly ModuleVariable[]): { module: string; vars: ModuleVariable[] }[] {
  const out: { module: string; vars: ModuleVariable[] }[] = [];
  for (const v of vars) {
    let group = out.find((g) => g.module.toLowerCase() === v.module.toLowerCase());
    if (!group) {
      group = { module: v.module, vars: [] };
      out.push(group);
    }
    group.vars.push(v);
  }
  return out;
}
