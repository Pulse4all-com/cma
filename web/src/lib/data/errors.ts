/**
 * The data layer's error contract, in a module without imports, so a screen or the mock can name a refusal
 * without loading the database driver (the IT audit of 17 October 2026, finding CQ-05; before it the class
 * lived in lib/db/client.ts and two screens imported it from there).
 */

/** SQLSTATEs raised by the functions of migrations 0002 and 0003 and their additions. The API maps codes, not text. */
export type CmaSqlState = 'CMA01' | 'CMA02' | 'CMA03' | 'CMA04' | 'CMA05' | 'CMA06';

export const CMA_SQLSTATE = {
  CMA01: 'no acting user or user inactive',
  CMA02: 'not found or not yours',
  CMA03: 'workday already ended',
  CMA04: 'invalid correction or event',
  CMA05: 'tenant configuration missing',
  CMA06: 'not permitted',
} as const satisfies Record<CmaSqlState, string>;

export class CmaDbError extends Error {
  readonly sqlState: CmaSqlState | 'DB_UNAVAILABLE' | 'DB_ERROR';
  readonly detail: string | undefined;
  constructor(sqlState: CmaDbError['sqlState'], message: string, detail?: string) {
    super(message);
    this.name = 'CmaDbError';
    this.sqlState = sqlState;
    this.detail = detail;
  }
}

export function isCmaSqlState(code: unknown): code is CmaSqlState {
  return typeof code === 'string' && code in CMA_SQLSTATE;
}
