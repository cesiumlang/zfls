// Fortran in a debugger, for zfls's debug adapter (gdbAdapter.ts): gdb's
// variables read as Fortran. The bounds of an array from gdb's type string,
// the names and expressions of its elements, previews of values, the
// hidden arguments to leave out, the dynamic type of a polymorphic object,
// the runtime's error functions, and the expression under the mouse. No
// `vscode` import (see test/unit).

/** A dimension of an array: `lo:hi`; `:` (deferred: not allocated, not
 * associated) has neither, `*` (assumed size) no `hi` */
export interface Dim {
  lo?: number;
  hi?: number;
}

/** An array as gdb's type string gives it: `real(kind=4), allocatable (2:3,-1:1)` */
export interface ArrayType {
  /** The type of its elements, without `, allocatable` */
  element: string;
  allocatable: boolean;
  dims: Dim[];
}

const DIM = /^(?:(-?\d+)|(-?\d+):(-?\d+)|:|\*|(-?\d+):\*)$/;

/** The array of a gdb type string, or undefined for a scalar */
export function arrayType(type: string | undefined): ArrayType | undefined {
  const m = /^(.*\S)\s+\(([^()]*)\)$/.exec(type ?? "");
  if (!m) {
    return undefined;
  }
  const dims: Dim[] = [];
  for (const d of m[2].split(",")) {
    const p = DIM.exec(d.trim());
    if (!p) {
      return undefined;
    }
    if (p[1] !== undefined) {
      dims.push({ lo: 1, hi: Number(p[1]) });
    } else if (p[2] !== undefined) {
      dims.push({ lo: Number(p[2]), hi: Number(p[3]) });
    } else if (p[4] !== undefined) {
      dims.push({ lo: Number(p[4]) });
    } else {
      dims.push(d.trim() === "*" ? { lo: 1 } : {});
    }
  }
  const allocatable = /,\s*allocatable$/i.test(m[1]);
  return { element: m[1].replace(/,\s*allocatable$/i, ""), allocatable, dims };
}

/** Whether the array has no elements to show: deferred-shape and not
 * allocated or not associated */
export function isUnallocated(a: ArrayType): boolean {
  return a.dims.every((d) => d.lo === undefined);
}

/** The extent of a dimension, when known */
export function extent(d: Dim): number | undefined {
  return d.lo !== undefined && d.hi !== undefined ? Math.max(0, d.hi - d.lo + 1) : undefined;
}

/** Where a node is in an array: its expression, the array's dimensions,
 * and the subscripts already chosen for its last ones. gdb gives an array
 * of rank n as its last dimension's elements, each of rank n-1. */
export interface ArrayContext {
  /** The array's expression, when it has one */
  expr?: string;
  dims: Dim[];
  /** Subscripts of the last dimensions, outermost last */
  fixed: string[];
  /** For the elements of a section (`a(:,101:200)`), which gdb numbers
   * from 1 in each dimension: what to add to gdb's name, by dimension */
  offsets?: number[];
}

/** The rank of the node an array context describes */
export function rankOf(ctx: ArrayContext): number {
  return ctx.dims.length - ctx.fixed.length;
}

/** The subscript of gdb's `name` for an element of the node of `ctx` */
function subscript(ctx: ArrayContext, name: string): string {
  const offset = ctx.offsets?.[rankOf(ctx) - 1];
  return offset !== undefined && /^-?\d+$/.test(name) ? String(Number(name) + offset) : name;
}

/** The subscript of the first element of the node */
function firstIndex(ctx: ArrayContext): number {
  const offset = ctx.offsets?.[rankOf(ctx) - 1];
  return offset !== undefined ? offset + 1 : (indexedDim(ctx).lo ?? 1);
}

export interface Element {
  /** `(2)`, `(2,-1)`, `(:,-1)` */
  name: string;
  evaluateName?: string;
  /** For an element that is itself an array (a column): its context */
  sub?: ArrayContext;
}

/** The name, expression and context of gdb's child `name` of an array node */
export function element(ctx: ArrayContext, name: string): Element {
  const rank = rankOf(ctx);
  const s = subscript(ctx, name);
  const subs = [...Array<string>(Math.max(0, rank - 1)).fill(":"), s, ...ctx.fixed];
  const list = subs.join(",");
  return {
    name: `(${list})`,
    evaluateName: ctx.expr !== undefined ? `${ctx.expr}(${list})` : undefined,
    sub: rank > 1 ? { expr: ctx.expr, dims: ctx.dims, fixed: [s, ...ctx.fixed], offsets: ctx.offsets } : undefined,
  };
}

/** The node's dimension that its children index: the last not chosen */
export function indexedDim(ctx: ArrayContext): Dim {
  return ctx.dims[rankOf(ctx) - 1] ?? {};
}

export interface Chunk {
  /** 0-based position of its first element */
  start: number;
  count: number;
}

/** The chunks a node of `count` elements is shown in: none up to `size`,
 * else at most `size` chunks of a power of `size` */
export function chunks(count: number, size = 100): Chunk[] {
  if (count <= size) {
    return [];
  }
  let per = size;
  while (count > per * size) {
    per *= size;
  }
  const out: Chunk[] = [];
  for (let start = 0; start < count; start += per) {
    out.push({ start, count: Math.min(per, count - start) });
  }
  return out;
}

/** The section of a chunk of a node: its subscripts (`(:,101:200)`), and
 * its expression when the array has one */
export function chunkSection(ctx: ArrayContext, chunk: Chunk): { name: string; evaluateName?: string } {
  const lo = firstIndex(ctx) + chunk.start;
  const subs = [...Array<string>(Math.max(0, rankOf(ctx) - 1)).fill(":"), `${lo}:${lo + chunk.count - 1}`, ...ctx.fixed];
  const list = subs.join(",");
  return { name: `(${list})`, evaluateName: ctx.expr !== undefined ? `${ctx.expr}(${list})` : undefined };
}

/** The context of the elements of a chunk's section, which gdb numbers
 * from 1 in each of its dimensions */
export function chunkContext(ctx: ArrayContext, chunk: Chunk): ArrayContext {
  const rank = rankOf(ctx);
  const offsets = ctx.dims.map((d, i) =>
    i === rank - 1 ? firstIndex(ctx) + chunk.start - 1 : (ctx.offsets?.[i] ?? (d.lo ?? 1) - 1),
  );
  return { ...ctx, offsets };
}

// Values

/** The C types gdb gives the values of expressions (`a(2) + 1`), as Fortran's */
const C_TYPES: Record<string, string> = {
  int: "integer(kind=4)",
  long: "integer(kind=8)",
  "long long": "integer(kind=8)",
  float: "real(kind=4)",
  double: "real(kind=8)",
  "long double": "real(kind=10)",
};

/** A type as Fortran names it: gdb's C types of expressions translated */
export function fortranType(type: string | undefined): string | undefined {
  return type !== undefined ? (C_TYPES[type] ?? type) : undefined;
}

/** A real or complex value as Fortran writes it: `6` -> `6.0` */
export function fortranNumber(value: string, type: string | undefined): string {
  const t = (type ?? "").toLowerCase();
  const real = (v: string): string => (/^[-+]?\d+$/.test(v.trim()) ? `${v.trim()}.0` : v.trim());
  if (t.startsWith("real")) {
    return real(value);
  }
  if (t.startsWith("complex")) {
    const m = /^\((.*),(.*)\)$/.exec(value.trim());
    return m ? `(${real(m[1])}, ${real(m[2])})` : value;
  }
  return value;
}

/** The previews of values: what an array or a derived type shows before
 * it is expanded */
const MAX_PREVIEW = 6;

/** `[1.0, 2.0, 3.0]`, `[1.0, 2.0, …]` */
export function arrayPreview(values: readonly string[], total: number): string {
  const shown = values.slice(0, MAX_PREVIEW);
  return `[${shown.join(", ")}${total > shown.length ? ", …" : ""}]`;
}

/** The shape of an array of rank 2 or more: `[2×3]` */
export function shapePreview(dims: readonly Dim[]): string {
  return `[${dims.map((d) => extent(d) ?? "?").join("×")}]`;
}

/** `point(x=9.0, y=-2.0, id=7)` */
export function structPreview(typeName: string, components: readonly { name: string; value: string }[]): string {
  const shown = components.slice(0, 4).map((c) => `${c.name}=${c.value}`);
  return `${typeName}(${shown.join(", ")}${components.length > shown.length ? ", …" : ""})`;
}

/** The name of a derived type of a gdb type string: `Type point` -> `point` */
export function derivedTypeName(type: string | undefined): string | undefined {
  const m = /^Type (\S+)$/.exec(type ?? "");
  return m && !m[1].startsWith("__class_") ? m[1] : undefined;
}

/** The type a gdb pointer points to: `PTR TO -> ( character*7 )` */
export function pointerTarget(type: string | undefined): string | undefined {
  return /^PTR TO -> \( (.*) \)$/.exec(type ?? "")?.[1];
}

/** Whether a pointer's value is null */
export function isNullPointer(value: string): boolean {
  return /^0x0+(\s|$)/i.test(value.trim());
}

/** Whether a variable is gfortran's hidden length of a CHARACTER argument
 * (`_s` for `s`), which the program never names */
export function isHiddenLength(name: string, siblings: readonly { name: string; type?: string }[]): boolean {
  const m = /^_(\w+)$/.exec(name);
  if (!m) {
    return false;
  }
  const of = siblings.find((s) => s.name.toLowerCase() === m[1].toLowerCase());
  return of !== undefined && /character/i.test(of.type ?? "");
}

// Polymorphic objects (CLASS)

/** Whether a gdb type is gfortran's wrapper of a polymorphic object, whose
 * components are `_data` (the object) and `_vptr` (its dynamic type) */
export function isClassWrapper(type: string | undefined): boolean {
  return /^Type __class_/.test(type ?? "");
}

/** The dynamic type of a polymorphic object, from its `_vptr` value
 * (`0x7ff6... <__grid_MOD___vtab_grid_Tagged>`): the type's module and
 * name, for gdb's `module::type`; undefined for an intrinsic type or one
 * outside a module */
export function dynamicType(vptrValue: string): { module: string; name: string } | undefined {
  const m = /<__(\w+?)_MOD___vtab_(\w+)>/.exec(vptrValue);
  if (!m) {
    return undefined;
  }
  const module = m[1];
  const rest = m[2];
  if (!rest.toLowerCase().startsWith(module.toLowerCase() + "_")) {
    return undefined;
  }
  const name = rest.slice(module.length + 1).toLowerCase();
  return name ? { module, name } : undefined;
}

/** The address of a pointer value: `0x7ff6c1d640c0 <tg>` -> `0x7ff6c1d640c0` */
export function addressOf(value: string): string | undefined {
  return /^(0x[0-9a-f]+)/i.exec(value.trim())?.[1];
}

/** The gdb command that sets the convenience variable `$name` to the
 * object at `address` as a pointer to its dynamic type */
export function castCommand(variable: string, address: string, type: { module: string; name: string }): string {
  return (
    `python gdb.set_convenience_variable(${JSON.stringify(variable)}, ` +
    `gdb.Value(${address}).cast(gdb.lookup_type(${JSON.stringify(`${type.module}::${type.name}`)}).pointer()))`
  );
}

// Errors at run time

/** The functions of the Fortran runtimes that a program calls on an error
 * (an array bound exceeded with `-fcheck=bounds`, a failed allocation, an
 * I/O error without `iostat=`) or `ERROR STOP`: gfortran's, LLVM Flang's,
 * Intel's */
export const RUNTIME_ERROR_FUNCTIONS: readonly string[] = [
  "_gfortran_runtime_error",
  "_gfortran_runtime_error_at",
  "_gfortran_os_error",
  "_gfortran_os_error_at",
  "_gfortran_error_stop_string",
  "_gfortran_error_stop_numeric",
  "_FortranAReportFatalUserError",
  "for__issue_diagnostic",
];

/** Whether a runtime function is one of `ERROR STOP` */
export function isErrorStop(fn: string): boolean {
  return /error_stop/i.test(fn);
}

// The expression under the mouse

/** The start of the expression that ends with the name at `start`..`end`
 * of `line`: its components' parents (`p%x`, `a(i)%x`), for hovers */
export function hoverExpressionStart(line: string, start: number): number {
  let at = start;
  for (;;) {
    let i = at - 1;
    while (i >= 0 && line[i] === " ") {
      i--;
    }
    if (line[i] !== "%") {
      return at;
    }
    i--;
    while (i >= 0 && line[i] === " ") {
      i--;
    }
    // a subscript: back to its opening parenthesis
    if (line[i] === ")") {
      let depth = 0;
      for (; i >= 0; i--) {
        if (line[i] === ")") {
          depth++;
        } else if (line[i] === "(" && --depth === 0) {
          break;
        }
      }
      if (i < 0) {
        return at;
      }
      i--;
    }
    let j = i;
    while (j >= 0 && /\w/.test(line[j])) {
      j--;
    }
    if (j === i || !/[a-z]/i.test(line[j + 1])) {
      return at;
    }
    at = j + 1;
  }
}
