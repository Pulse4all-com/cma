import "server-only";
import { ApiError } from "@/lib/api/respond";
import type { AbsenceTypeInput, ConfigAppLinkInput, ConfigStatusInput, SkillDimension, SkillInputRow, SkillLevel, TeamInput } from "@/lib/data";

/**
 * Parameter checks of the configuration routes (migration 0005a): shape and bounds only, so a bad
 * body is a 400 before the database is asked; what a value means (a frozen flag, the last working
 * status, an unknown permission) is the database's answer. No key, label or address is assumed.
 */

export function checkKey(value: unknown, pattern: RegExp): string {
  if (typeof value !== "string" || !pattern.test(value) || value.length > 40) throw new ApiError(400, "invalid_key", "key has a wrong form");
  return value;
}

function text(b: Record<string, unknown>, name: string, max: number): string {
  const v = b[name];
  if (typeof v !== "string" || v.trim().length === 0 || v.trim().length > max) throw new ApiError(400, `invalid_${name}`, `${name} must be 1 to ${max} characters`);
  return v.trim();
}

function flag(b: Record<string, unknown>, name: string): boolean {
  if (typeof b[name] !== "boolean") throw new ApiError(400, `invalid_${name}`, `${name} must be true or false`);
  return b[name] as boolean;
}

function order(b: Record<string, unknown>): number {
  const v = b.sortOrder ?? 100;
  if (typeof v !== "number" || !Number.isInteger(v) || v < 0 || v > 9999) throw new ApiError(400, "invalid_sort_order", "sortOrder must be a whole number from 0 to 9999");
  return v;
}

export function checkStatusInput(b: Record<string, unknown>): ConfigStatusInput {
  return {
    key: checkKey(b.key, /^[a-z0-9_]+$/),
    name: text(b, "name", 40),
    isWorking: flag(b, "isWorking"), isProductive: flag(b, "isProductive"), isPaid: flag(b, "isPaid"), isBillable: flag(b, "isBillable"),
    sortOrder: order(b),
  };
}

export function checkLinkInput(b: Record<string, unknown>): ConfigAppLinkInput {
  const address = text(b, "address", 2000);
  if (!/^https:\/\/[^\s]+$/.test(address)) throw new ApiError(400, "invalid_address", "address must start with https:// and hold no spaces");
  const permissionKey = b.permissionKey == null || b.permissionKey === "" ? null : b.permissionKey;
  if (permissionKey !== null && (typeof permissionKey !== "string" || !/^[a-z_]+(\.[a-z_]+)*$/.test(permissionKey))) {
    throw new ApiError(400, "invalid_permission", "permissionKey must be a permission key or empty");
  }
  return { key: checkKey(b.key, /^[a-z0-9]+(-[a-z0-9]+)*$/), label: text(b, "label", 60), address, permissionKey, sortOrder: order(b) };
}

export function checkAbsenceInput(b: Record<string, unknown>): AbsenceTypeInput {
  return { key: checkKey(b.key, /^[a-z0-9_]+$/), name: text(b, "name", 40), isPaid: flag(b, "isPaid"), sortOrder: order(b) };
}

export function checkTeamInput(b: Record<string, unknown>): TeamInput {
  const markets = b.markets ?? [];
  if (!Array.isArray(markets) || markets.length > 50 || markets.some((m) => typeof m !== "string" || !/^[a-z]{2}$/.test(m))) {
    throw new ApiError(400, "invalid_markets", "markets must be two-letter lowercase tokens");
  }
  return { key: checkKey(b.key, /^[a-z0-9]+(-[a-z0-9]+)*$/), name: text(b, "name", 60), markets: markets as string[], sortOrder: order(b) };
}

const DIMENSIONS: readonly SkillDimension[] = ["language", "work_type", "channel"];

export function checkDimension(value: unknown): SkillDimension {
  if (typeof value !== "string" || !DIMENSIONS.includes(value as SkillDimension)) throw new ApiError(400, "invalid_dimension", "dimension must be language, work_type or channel");
  return value as SkillDimension;
}

export function checkSkillInput(b: Record<string, unknown>): { input: SkillInputRow; active: boolean } {
  return {
    input: { dimension: checkDimension(b.dimension), key: checkKey(b.key, /^[a-z0-9]+(-[a-z0-9]+)*$/), name: text(b, "name", 40), sortOrder: order(b) },
    active: b.active === undefined ? true : flag(b, "active"),
  };
}

export function checkLevels(b: Record<string, unknown>): SkillLevel[] {
  const levels = b.levels;
  if (!Array.isArray(levels) || levels.length > 10) throw new ApiError(400, "invalid_levels", "levels must be a list of at most ten { level, name }");
  const out: SkillLevel[] = [];
  for (const l of levels as unknown[]) {
    const x = l as Record<string, unknown>;
    if (!x || typeof x !== "object" || typeof x.level !== "number" || !Number.isInteger(x.level) || x.level < 1 || x.level > 10
        || typeof x.name !== "string" || x.name.trim().length === 0 || x.name.length > 40) {
      throw new ApiError(400, "invalid_levels", "each level is a whole number from 1 to 10 with a name");
    }
    out.push({ level: x.level, name: x.name.trim() });
  }
  if (new Set(out.map((l) => l.level)).size !== out.length) throw new ApiError(400, "invalid_levels", "levels must be distinct");
  return out;
}

export function checkTargetInput(b: Record<string, unknown>): { teamKey: string; skillKey: string; weekday: number; minCount: number | null } {
  const weekday = b.weekday;
  if (typeof weekday !== "number" || !Number.isInteger(weekday) || weekday < 1 || weekday > 7) throw new ApiError(400, "invalid_weekday", "weekday is 1 (Monday) to 7 (Sunday)");
  const minCount = b.minCount ?? 0;
  if (typeof minCount !== "number" || !Number.isInteger(minCount) || minCount < 0 || minCount > 99) throw new ApiError(400, "invalid_min_count", "minCount is 0 to 99; 0 clears");
  return { teamKey: checkKey(b.teamKey, /^[a-z0-9]+(-[a-z0-9]+)*$/), skillKey: checkKey(b.skillKey, /^[a-z0-9]+(-[a-z0-9]+)*$/), weekday, minCount: minCount === 0 ? null : minCount };
}

export function checkSettingInput(b: Record<string, unknown>): { key: string; value: string | null } {
  const key = b.key;
  if (typeof key !== "string" || !/^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$/.test(key)) throw new ApiError(400, "invalid_key", "key must be a setting key");
  const value = b.value ?? null;
  if (value !== null && (typeof value !== "string" || value.length === 0 || value.length > 100)) throw new ApiError(400, "invalid_value", "value must be text, or null to reset");
  return { key, value };
}
