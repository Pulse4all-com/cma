export declare const SESSION_OPTION_RULES: Readonly<Record<'jit' | 'work_mem' | 'random_page_cost', RegExp>>;
export declare function parseSessionOptions(raw: string | undefined | null): { pairs: [string, string][]; options: string | undefined };
export declare function sessionPoolOptions(env?: Record<string, string | undefined>): { options?: string };
